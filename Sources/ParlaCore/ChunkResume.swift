import Foundation

/// Crash-and-suspension survival for the long-audio path.
///
/// A chunked transcription accumulated every chunk's result in memory and wrote the note exactly once, at the
/// end. On iOS that is a real loss and not a theoretical one: the OS suspends a backgrounded app within
/// seconds and may jetsam it outright, so a phone call, a lock, or memory pressure during a 40-minute job threw
/// away all 40 minutes — on the Pro headline feature, on the platform shipping first, and with no trace left
/// that any work had happened.
///
/// What this can and cannot do is worth being exact about. iOS does NOT permit an app to keep computing in the
/// background for an arbitrary length of time. A background-task assertion buys a short grace window, and the
/// `audio` background mode is for playing or recording audio — claiming it to run inference would be a misuse
/// and a review risk. So the goal here is not "keep going in the background"; it is "never lose what is already
/// done, and pick up where it stopped". After this, an interruption costs at most the chunk in flight.
///
/// The resume is only sound because chunk boundaries are DETERMINISTIC: `AudioChunker` cuts at fixed
/// `chunkLengthSec` offsets, so chunk *k* of a given file is always the same audio. Anything that would change
/// that mapping — a different source, model, language, translate flag, chunk length, or chunk count — makes the
/// record inapplicable, and it is discarded rather than trusted (`canResume`).
public struct ChunkedJobProgress: Codable, Sendable, Equatable {
    /// One finished chunk, in the chunk's OWN timeline. Stitching into the global timeline happens at the end,
    /// from these, exactly as it did when they lived only in memory.
    public struct Chunk: Codable, Sendable, Equatable {
        public var segments: [Segment]
        public var text: String
        public var language: String
        /// Whether this entry is the "(chunk N failed)" placeholder rather than a transcription.
        ///
        /// Optional, per the same rule every persisted field here follows: a record written by an older build
        /// must still decode. Without this flag a resume treated a placeholder as a finished chunk and deleted
        /// its audio unretried — so a TRANSIENT failure, memory pressure being the obvious one and also the
        /// exact condition that precedes the jetsam this whole feature exists for, became permanent. Before
        /// resume existed the same interruption re-ran the file and the chunk usually succeeded.
        public var failed: Bool?
        public init(segments: [Segment], text: String, language: String, failed: Bool? = nil) {
            self.segments = segments; self.text = text; self.language = language; self.failed = failed
        }
    }

    public var sourcePath: String
    public var model: String
    /// The REQUESTED language (nil = Auto), not the detected one — it is part of what makes a chunk's result
    /// reproducible, so a record made under a different pin must not be reused.
    public var requestedLanguage: String?
    public var translate: Bool
    public var chunkLengthSec: Double
    public var totalChunks: Int
    public var audioDuration: Double
    /// The source's size and modification time when the record was written.
    ///
    /// Identity, not metadata. Without them `canResume` compared only the PATH and the chunk count — and the
    /// count is a two-minute-wide bucket, so a 38:10 recording and a 39:50 one are both twenty chunks. A
    /// watched folder overwriting the same filename, or a Shortcut writing to `tmp/<filename>` twice, then
    /// resumed chunks 0…k of the OLD audio into the NEW note, with plausible timecodes, no error and nothing
    /// to notice. That is precisely the corruption this type's own doc claims to prevent.
    public var sourceSize: Int64?
    public var sourceModified: Double?
    /// What the model heard on chunk 0 — asked once, and would otherwise be lost on resume, taking the
    /// wrong-language nudge with it on exactly the long files where a wrong pin costs the most.
    public var heardLanguage: String?
    public var heardConfidence: Double?
    /// Completed chunks, a PREFIX of the chunk list: `done[k]` is chunk `k`. Resume starts at `done.count`.
    public var done: [Chunk]

    public init(sourcePath: String, model: String, requestedLanguage: String?, translate: Bool,
                chunkLengthSec: Double, totalChunks: Int, audioDuration: Double,
                sourceSize: Int64? = nil, sourceModified: Double? = nil,
                heardLanguage: String? = nil, heardConfidence: Double? = nil, done: [Chunk] = []) {
        self.sourcePath = sourcePath
        self.model = model
        self.requestedLanguage = requestedLanguage
        self.translate = translate
        self.chunkLengthSec = chunkLengthSec
        self.totalChunks = totalChunks
        self.audioDuration = audioDuration
        self.sourceSize = sourceSize
        self.sourceModified = sourceModified
        self.heardLanguage = heardLanguage
        self.heardConfidence = heardConfidence
        self.done = done
    }

    /// Does this record describe the job about to run — and is it worth resuming at all?
    ///
    /// Every field here changes what a chunk's audio or its transcription would be, so a mismatch means the
    /// stored chunks are answers to a different question. A record whose `done` count is at or past the total
    /// is also refused: it is either complete (the note was written, this is a leftover) or corrupt, and in
    /// both cases starting over is the honest answer.
    public func canResume(sourcePath: String, model: String, requestedLanguage: String?, translate: Bool,
                          chunkLengthSec: Double, totalChunks: Int,
                          fingerprint: SourceFingerprint?) -> Bool {
        // A record with no fingerprint predates this check; refuse it rather than trust a path.
        guard let fingerprint, sourceSize == fingerprint.size, sourceModified == fingerprint.modified else {
            return false
        }
        return self.sourcePath == sourcePath
            && self.model == model
            && self.requestedLanguage == requestedLanguage
            && self.translate == translate
            && self.chunkLengthSec == chunkLengthSec
            && self.totalChunks == totalChunks
            && !done.isEmpty
            && done.count < totalChunks
    }
}

/// What the source file looked like when a record was written. Cheap — one stat, no read — and enough to tell
/// "the same file" from "a different recording that happens to have the same name".
public struct SourceFingerprint: Sendable, Equatable {
    public let size: Int64
    public let modified: Double

    public init(size: Int64, modified: Double) { self.size = size; self.modified = modified }

    public init?(of url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        self.size = Int64(size)
        self.modified = modified.timeIntervalSince1970
    }
}

/// Where a long job's progress lives between chunks. One record at a time: the pipeline transcribes one file at
/// a time (the queue serialises them), so there is never a second job to interleave with.
///
/// Mirrors `HistoryStore`: a settable `fileURL` so tests never touch the user's real file. Writes are small
/// (one chunk's segments) and happen once per chunk — a couple of times a minute at the shipping chunk length,
/// which is nothing next to the inference it protects.
public enum ChunkProgressStore {
    /// `nonisolated(unsafe)`: the same deliberate global-mutable opt-out as `HistoryStore.fileURL` — written
    /// only in test setup, read on the main actor in production.
    nonisolated(unsafe) public static var fileURL: URL = defaultFileURL()

    public static func defaultFileURL() -> URL {
        let base = StorageRoot.defaultURL()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("chunk-progress.json")
    }

    public static func load() -> ChunkedJobProgress? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        // A corrupt record is DISCARDED, never salvaged. Unlike history — where a damaged file is the user's
        // archive and worth rescuing element by element — this is a resumption hint whose only failure mode is
        // transcribing from the start again. Trusting half of it could splice the wrong audio into a transcript.
        return try? JSONDecoder().decode(ChunkedJobProgress.self, from: data)
    }

    public static func save(_ progress: ChunkedJobProgress) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        // Atomic: the whole point is surviving a kill, and a half-written record read back as garbage would
        // turn "resume" into "start over" at exactly the moment it was supposed to help.
        try? data.write(to: fileURL, options: .atomic)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Drop a record that is too old to be worth resuming.
    ///
    /// This file holds the TEXT of every completed chunk. A job killed at 30 of 40 minutes leaves half an hour
    /// of the user's speech in cleartext beside the history, invisible in the UI, until some later long job
    /// happens to overwrite it. Resuming is worth a few days of that; forever is not. Called at launch, and the
    /// grace period matches the one the iOS import sweep uses for the same reason: unreferenced is not unwanted.
    public static func pruneIfStale(olderThan age: TimeInterval = 604_800, now: Date = Date()) {
        guard let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate else { return }
        if now.timeIntervalSince(modified) > age { clear() }
    }
}
