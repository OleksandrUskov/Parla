import Foundation

/// What a source file looked like when a record was written — and the ONLY thing that identifies a resumable
/// job. Cheap: one stat, no read.
///
/// It is not the path, and that is the whole point. The path is unstable in exactly the places this feature was
/// built for:
/// - **iOS**, where every share or picker import copies the file to `imports/<fresh UUID>/<name>`, so re-sharing
///   the same recording after a jetsam produced a path that had never been seen before and resume never once
///   fired on the platform it exists for;
/// - **the unknown-duration fallback**, which chunks a decoded temp WAV named `parla-decode-<uuid>.wav`,
///   regenerated on every run;
/// - and it is not even sufficient on macOS: a watched folder that overwrites the same filename, or a Shortcut
///   writing to `tmp/<filename>` twice, kept the path identical while the AUDIO changed.
///
/// Size and modification time are stable across all of those — measured, not assumed: `FileManager.copyItem`
/// preserves both, identically across repeated copies, which is what makes an iOS re-share match. And they are
/// what distinguishes a re-recording from the same recording, which the chunk count cannot: at a 120-second
/// chunk length it is a two-minute-wide bucket, so 38:10 and 39:50 are both twenty chunks.
public struct SourceFingerprint: Codable, Sendable, Equatable {
    public let name: String        // survives the iOS container copy, which preserves the original filename
    public let size: Int64
    public let modified: Double

    public init(name: String, size: Int64, modified: Double) {
        self.name = name; self.size = size; self.modified = modified
    }

    public init?(of url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        self.init(name: url.lastPathComponent, size: Int64(size), modified: modified.timeIntervalSince1970)
    }
}

/// Crash-and-suspension survival for the long-audio path.
///
/// A chunked transcription accumulated every chunk's result in memory and wrote the note exactly once, at the
/// end. On iOS that is a real loss and not a theoretical one: the OS suspends a backgrounded app within seconds
/// and may jetsam it outright, so a phone call, a lock, or memory pressure during a 40-minute job threw away all
/// 40 minutes — on the Pro headline feature, on the platform shipping first, and with no trace left that any
/// work had happened.
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
        /// exact condition that precedes the jetsam this feature exists for, became permanent. Before resume
        /// existed the same interruption re-ran the file and the chunk usually succeeded.
        public var failed: Bool?
        public init(segments: [Segment], text: String, language: String, failed: Bool? = nil) {
            self.segments = segments; self.text = text; self.language = language; self.failed = failed
        }
    }

    /// What identifies this job. Optional only so a record written before identity existed still decodes — it is
    /// then refused, because a record that cannot prove which file it belongs to is not one worth trusting.
    public var fingerprint: SourceFingerprint?
    /// Kept for diagnostics and for the log line, never for matching: see `SourceFingerprint`.
    public var sourcePath: String
    public var model: String
    /// The REQUESTED language (nil = Auto), not the detected one — it is part of what makes a chunk's result
    /// reproducible, so a record made under a different pin must not be reused.
    public var requestedLanguage: String?
    public var translate: Bool
    public var chunkLengthSec: Double
    public var totalChunks: Int
    public var audioDuration: Double
    /// What the model heard on chunk 0 — asked once, and would otherwise be lost on resume, taking the
    /// wrong-language nudge with it on exactly the long files where a wrong pin costs the most.
    public var heardLanguage: String?
    public var heardConfidence: Double?
    /// When this record was last written. Drives both the eviction order and the staleness sweep.
    public var updatedAt: Double?
    /// Completed chunks, a PREFIX of the chunk list: `done[k]` is chunk `k`. Resume starts at `done.count`.
    public var done: [Chunk]

    public init(fingerprint: SourceFingerprint?, sourcePath: String, model: String, requestedLanguage: String?,
                translate: Bool, chunkLengthSec: Double, totalChunks: Int, audioDuration: Double,
                heardLanguage: String? = nil, heardConfidence: Double? = nil,
                updatedAt: Double? = nil, done: [Chunk] = []) {
        self.fingerprint = fingerprint
        self.sourcePath = sourcePath
        self.model = model
        self.requestedLanguage = requestedLanguage
        self.translate = translate
        self.chunkLengthSec = chunkLengthSec
        self.totalChunks = totalChunks
        self.audioDuration = audioDuration
        self.heardLanguage = heardLanguage
        self.heardConfidence = heardConfidence
        self.updatedAt = updatedAt
        self.done = done
    }

    /// Does this record describe the job about to run — and is it worth resuming at all?
    ///
    /// Every field here changes what a chunk's audio or its transcription would be, so a mismatch means the
    /// stored chunks are answers to a different question. A record whose `done` count is at or past the total
    /// is also refused: it is either complete (the note was written, this is a leftover) or corrupt, and in
    /// both cases starting over is the honest answer.
    public func canResume(fingerprint other: SourceFingerprint?, model: String, requestedLanguage: String?,
                          translate: Bool, chunkLengthSec: Double, totalChunks: Int) -> Bool {
        guard let other, let fingerprint, fingerprint == other else { return false }
        return self.model == model
            && self.requestedLanguage == requestedLanguage
            && self.translate == translate
            && self.chunkLengthSec == chunkLengthSec
            && self.totalChunks == totalChunks
            && !done.isEmpty
            && done.count < totalChunks
    }
}

/// Where long jobs' progress lives between chunks.
///
/// Several records, keyed by fingerprint, not one slot. A single slot meant any other long job destroyed a live
/// record: a 40-minute job killed at 90%, then one unrelated long file, and the first job silently restarted
/// from chunk 0 — 36 minutes of inference re-run with nothing said. The pipeline only ever transcribes one file
/// at a time, so this is not about concurrency; a resume record is a CROSS-LAUNCH artifact and outlives the run
/// that made it.
///
/// Bounded on both axes, because this file holds the TEXT of every completed chunk: at most `maxRecords`, and
/// nothing older than the staleness sweep allows. Resuming is worth a few days of that residue on disk; forever
/// is not.
///
/// Mirrors `HistoryStore`: a settable `fileURL` so tests never touch the user's real file.
public enum ChunkProgressStore {
    /// `nonisolated(unsafe)`: the same deliberate global-mutable opt-out as `HistoryStore.fileURL` — written
    /// only in test setup, read on the main actor in production.
    nonisolated(unsafe) public static var fileURL: URL = defaultFileURL()

    /// Enough for the handful of long files anyone juggles at once; small enough that the residue stays bounded.
    public static let maxRecords = 4

    public static func defaultFileURL() -> URL {
        let base = StorageRoot.defaultURL()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("chunk-progress.json")
    }

    /// Every stored record, oldest first. A corrupt or older-format file reads as EMPTY rather than being
    /// salvaged: unlike history — where a damaged file is the user's archive and worth rescuing element by
    /// element — this is a resumption hint whose only failure mode is transcribing from the start again, and
    /// trusting half of it could splice the wrong audio into a transcript.
    public static func loadAll() -> [ChunkedJobProgress] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([ChunkedJobProgress].self, from: data) else { return [] }
        return records
    }

    /// The record for this source, if there is one.
    public static func load(for fingerprint: SourceFingerprint?) -> ChunkedJobProgress? {
        guard let fingerprint else { return nil }
        return loadAll().last { $0.fingerprint == fingerprint }
    }

    public static func save(_ progress: ChunkedJobProgress, now: Date = Date()) {
        // A record with no fingerprint can never be matched by `load(for:)` NOR removed by `remove(_:)` — both
        // refuse nil — so writing one produced an orphan that held the full transcript in cleartext, occupied
        // one of the LRU slots, and evicted a record that WAS resumable. It can happen for real: the stat runs
        // after the split, and a watched-folder file can vanish underneath the pipeline in between.
        guard progress.fingerprint != nil else { return }
        var stamped = progress
        stamped.updatedAt = now.timeIntervalSince1970
        var records = loadAll().filter { $0.fingerprint != stamped.fingerprint }
        records.append(stamped)                                   // most recently touched goes last…
        if records.count > maxRecords { records.removeFirst(records.count - maxRecords) }   // …so eviction is LRU
        write(records)
    }

    /// Drop the record for one source — its job finished, so the residue has no further purpose.
    public static func remove(_ fingerprint: SourceFingerprint?) {
        guard let fingerprint else { return }
        write(loadAll().filter { $0.fingerprint != fingerprint })
    }

    /// Drop everything. Called by "Clear history": these records hold the full TEXT of every completed chunk,
    /// and are not notes, so nothing else here reached them — a job killed at 30 of 40 minutes left half an hour
    /// of the user's speech in cleartext beside a history file they had just emptied.
    public static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Drop records nobody came back for. Called at launch; the grace period is the same reasoning the iOS
    /// import sweep uses — unreferenced is not unwanted, and a resume is worth a few days.
    public static func pruneIfStale(olderThan age: TimeInterval = 604_800, now: Date = Date()) {
        let kept = loadAll().filter { record in
            // No timestamp means we cannot tell how old it is. Deleting on "I can't tell" is the destructive
            // guess, so it is kept — and the record cap bounds it anyway.
            guard let updatedAt = record.updatedAt else { return true }
            return now.timeIntervalSince1970 - updatedAt <= age
        }
        write(kept)
    }

    private static func write(_ records: [ChunkedJobProgress]) {
        guard !records.isEmpty else { return clear() }
        guard let data = try? JSONEncoder().encode(records) else { return }
        // Atomic: the whole point is surviving a kill, and a half-written file read back as garbage would turn
        // "resume" into "start over" at exactly the moment it was supposed to help.
        try? data.write(to: fileURL, options: .atomic)
    }
}
