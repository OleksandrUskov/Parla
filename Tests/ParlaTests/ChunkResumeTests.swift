import XCTest
import AVFoundation
@testable import ParlaCore

/// A chunked transcription used to keep every chunk's result in memory and write the note exactly once, at the
/// end. On iOS that is a live data-loss path, not a theoretical one: the OS suspends a backgrounded app within
/// seconds and may jetsam it, so a phone call during a 40-minute job threw away all 40 minutes — on the Pro
/// headline feature, on the platform shipping first.
///
/// These tests pin the two halves of the fix: every finished chunk is on DISK before the next one starts, and a
/// job that starts again picks up where it stopped instead of paying for the same inference twice.
final class ChunkResumeTests: ParlaTestCase {

    /// Cuts a source into `count` chunks with STABLE, ordered names, so a test can tell which chunk the engine
    /// was asked for. Real chunk boundaries are deterministic too — that is what makes resuming sound at all.
    private final class MultiChunkDecoder: AudioDecoding, @unchecked Sendable {
        let count: Int
        init(count: Int) { self.count = count }
        var isChunkingAvailable: Bool { true }

        func decodeToWav16k(_ src: URL) throws -> URL { try Self.silentWav(named: "decoded", in: nil) }
        func splitIntoChunks(_ src: URL, chunkLength: Double) throws -> [URL] {
            // A DEDICATED directory: `transcribeChunked` deletes the chunks' parent, and returning a chunk from
            // the shared temp root once made that delete take out /var/folders/<user>/T itself.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("resume-chunks-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return try (0..<count).map { try Self.silentWav(named: "chunk-\($0)", in: dir) }
        }
        func renderPlayableM4a(from src: URL, to dest: URL) throws { throw AudioDecodingError.noDecoderAvailable }
        func renderPlayableWav(from src: URL, to dest: URL) throws { throw AudioDecodingError.noDecoderAvailable }

        static func silentWav(named: String, in dir: URL?) throws -> URL {
            let url = (dir ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("\(named)-\(UUID().uuidString).wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            try file.write(from: buffer)
            return url
        }
    }

    /// Records which chunks it was asked for, and — the point of the exercise — how much was already persisted
    /// at the moment each call began. No lock: the chunk loop awaits each call before starting the next, so
    /// these are strictly serialized (same reasoning as `CountingDecoder` in NoDoubleDecodeTests).
    private final class RecordingEngine: TranscribingEngine, @unchecked Sendable {
        private(set) var askedFor: [String] = []
        private(set) var persistedAtCallTime: [Int] = []

        func ensureLoaded(model: String, progress: @Sendable @escaping (ModelLoad) -> Void) async throws {}

        func transcribe(wavPath: String, language: String?, model: String,
                        translate: Bool, detectHeardLanguage: Bool) async throws -> EngineResult {
            let label = String(URL(fileURLWithPath: wavPath).lastPathComponent.prefix(7))   // "chunk-N"
            askedFor.append(label)
            persistedAtCallTime.append(await MainActor.run { ChunkProgressStore.load()?.done.count ?? 0 })
            return EngineResult(text: "T:\(label)", language: "ru",
                                segments: [Segment(start: 0, end: 1, text: "T:\(label)")],
                                duration: 1,
                                heard: detectHeardLanguage ? HeardLanguage(language: "ru", confidence: 0.9) : nil)
        }
        func transcribe(wavPath: String, language: String?, model: String, translate: Bool) async throws -> EngineResult {
            try await transcribe(wavPath: wavPath, language: language, model: model,
                                 translate: translate, detectHeardLanguage: false)
        }
        func transcribe(samples: [Float], language: String?, model: String) async throws -> EngineResult {
            EngineResult(text: "ok", language: "ru", segments: [], duration: 1)
        }
        func deleteModel(_ name: String) async throws {}
    }

    /// A source the pipeline must route through the decoder (a `.wav` would go straight to the engine).
    /// A stable stand-in for a real file's identity, so the pure truth table needs no filesystem.
    static let fixedFingerprint = SourceFingerprint(size: 1234, modified: 1_700_000_000)

    private static func source() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resume-src-\(UUID().uuidString).ogg")
        try Data("OggS\u{01}\u{00}".utf8).write(to: url)
        return url
    }

    @MainActor
    private func makeModel(chunks: Int, engine: RecordingEngine) -> AppModel {
        let m = AppModel(engine: engine, ai: NoopAIService(), embedder: NoopEmbedder())
        m.decoder = MultiChunkDecoder(count: chunks)
        m.isProUser = { true }                             // the length gate is not what is under test
        m.language = "ru"                                  // pin it, so the record's requestedLanguage is stable
        m.mediaDuration = { @Sendable _ in 45 * 60 }       // well past the chunking threshold
        return m
    }

    @MainActor
    private func run(_ m: AppModel, source: URL) async {
        m.handleDrop(urls: [source])
        await m.currentTranscriptionTask?.value            // handleDrop only ENQUEUES; the work runs in a task
    }

    // MARK: The persistence half

    /// THE data-loss fix: chunk *k* only ever starts once chunks 0…k-1 are on disk. Before this the whole job
    /// lived in memory until the very end, so an interruption at 95% cost 100%.
    @MainActor func testEveryFinishedChunkIsOnDiskBeforeTheNextOneStarts() async throws {
        let src = try Self.source()
        defer { try? FileManager.default.removeItem(at: src) }
        let engine = RecordingEngine()
        await run(makeModel(chunks: 4, engine: engine), source: src)

        XCTAssertEqual(engine.askedFor, ["chunk-0", "chunk-1", "chunk-2", "chunk-3"])
        XCTAssertEqual(engine.persistedAtCallTime, [0, 1, 2, 3],
                       "each chunk must find its predecessors already written — that is what survives a kill")
    }

    /// …and once the note exists the record has done its job. Leaving it behind would make the NEXT run of the
    /// same file resume into a transcript that is already saved.
    @MainActor func testTheRecordIsGoneOnceTheJobFinishes() async throws {
        let src = try Self.source()
        defer { try? FileManager.default.removeItem(at: src) }
        let m = makeModel(chunks: 3, engine: RecordingEngine())
        await run(m, source: src)

        XCTAssertEqual(m.history.count, 1, "the note was written")
        XCTAssertNil(ChunkProgressStore.load(), "a finished job must not leave a resume record behind")
    }

    // MARK: The resume half

    /// The payoff: an interrupted job pays only for what is left. The split runs again — chunk WAVs live in a
    /// temp directory the OS may purge — but inference, which is the expensive half, is not repeated.
    @MainActor func testAResumedJobOnlyTranscribesWhatIsLeft() async throws {
        let src = try Self.source()
        defer { try? FileManager.default.removeItem(at: src) }
        let engine = RecordingEngine()
        let m = makeModel(chunks: 4, engine: engine)

        // As if the app had been killed after chunk 1 of 4.
        ChunkProgressStore.save(ChunkedJobProgress(
            sourcePath: src.path, model: m.selectedModel, requestedLanguage: "ru", translate: false,
            chunkLengthSec: AudioChunker.chunkLengthSec, totalChunks: 4, audioDuration: 45 * 60,
            sourceSize: SourceFingerprint(of: src)?.size, sourceModified: SourceFingerprint(of: src)?.modified,
            heardLanguage: "ru", heardConfidence: 0.9,
            done: [.init(segments: [Segment(start: 0, end: 1, text: "OLD:0")], text: "OLD:0", language: "ru"),
                   .init(segments: [Segment(start: 0, end: 1, text: "OLD:1")], text: "OLD:1", language: "ru")]))

        await run(m, source: src)

        XCTAssertEqual(engine.askedFor, ["chunk-2", "chunk-3"],
                       "the first two chunks were already done and must not be transcribed again")
        let text = try XCTUnwrap(m.history.first?.text)
        XCTAssertTrue(text.contains("OLD:0") && text.contains("OLD:1"),
                      "the recovered work must appear in the transcript, not be silently dropped")
        XCTAssertTrue(text.contains("T:chunk-2") && text.contains("T:chunk-3"))
        XCTAssertLessThan(text.range(of: "OLD:0")!.lowerBound, text.range(of: "T:chunk-2")!.lowerBound,
                          "recovered chunks keep their place in the timeline")
    }

    /// "What the model heard" is asked ONCE, on chunk 0 — which a resumed run does not re-transcribe. Restoring
    /// it from the record is therefore the only way the wrong-language nudge survives an interruption, and that
    /// nudge matters most on exactly these files: a wrong pin costs ~9× the errors, and on a long recording the
    /// user has the most to lose. Dropping it would have been an invisible regression — no failure, just a
    /// warning that silently never appears.
    @MainActor func testAResumedJobStillKnowsWhatTheModelHeard() async throws {
        let src = try Self.source()
        defer { try? FileManager.default.removeItem(at: src) }
        let engine = RecordingEngine()
        let m = makeModel(chunks: 3, engine: engine)      // pinned "ru"

        ChunkProgressStore.save(ChunkedJobProgress(
            sourcePath: src.path, model: m.selectedModel, requestedLanguage: "ru", translate: false,
            chunkLengthSec: AudioChunker.chunkLengthSec, totalChunks: 3, audioDuration: 45 * 60,
            sourceSize: SourceFingerprint(of: src)?.size, sourceModified: SourceFingerprint(of: src)?.modified,
            heardLanguage: "en", heardConfidence: 0.95,   // ← chunk 0 heard ENGLISH, and is not re-run
            done: [.init(segments: [], text: "OLD:0", language: "en")]))

        await run(m, source: src)

        XCTAssertEqual(engine.askedFor, ["chunk-1", "chunk-2"])
        let nudge = try XCTUnwrap(m.languageSuggestion,
                                  "the recovered detection must still raise the wrong-language nudge")
        XCTAssertEqual(nudge.detected, "en")
    }

    /// A record from a DIFFERENT job must be ignored rather than spliced in. Its chunks are answers to another
    /// question, and quietly reusing them would corrupt a transcript in a way no error would ever report.
    @MainActor func testARecordThatDescribesAnotherJobIsDiscarded() async throws {
        let src = try Self.source()
        defer { try? FileManager.default.removeItem(at: src) }
        let engine = RecordingEngine()
        let m = makeModel(chunks: 3, engine: engine)

        ChunkProgressStore.save(ChunkedJobProgress(
            sourcePath: "/somewhere/else.ogg",            // ← a different file entirely
            model: m.selectedModel, requestedLanguage: "ru", translate: false,
            chunkLengthSec: AudioChunker.chunkLengthSec, totalChunks: 3, audioDuration: 45 * 60,
            done: [.init(segments: [], text: "FOREIGN", language: "ru")]))

        await run(m, source: src)

        XCTAssertEqual(engine.askedFor, ["chunk-0", "chunk-1", "chunk-2"], "every chunk must be transcribed")
        XCTAssertFalse(try XCTUnwrap(m.history.first?.text).contains("FOREIGN"))
    }

    // MARK: The record's own rules

    /// Each field in `canResume` changes what a chunk's audio or its transcription would be, so each one alone
    /// must be enough to refuse the record.
    func testCanResumeRefusesAnythingThatWouldChangeTheChunks() {
        let base = ChunkedJobProgress(sourcePath: "/a.ogg", model: "m", requestedLanguage: "ru", translate: false,
                                      chunkLengthSec: 120, totalChunks: 4, audioDuration: 600,
                                      sourceSize: Self.fixedFingerprint.size,
                                      sourceModified: Self.fixedFingerprint.modified,
                                      done: [.init(segments: [], text: "x", language: "ru")])
        func ok(_ p: ChunkedJobProgress, source: String = "/a.ogg", model: String = "m",
                lang: String? = "ru", translate: Bool = false, len: Double = 120, total: Int = 4,
                fingerprint: SourceFingerprint? = Self.fixedFingerprint) -> Bool {
            p.canResume(sourcePath: source, model: model, requestedLanguage: lang,
                        translate: translate, chunkLengthSec: len, totalChunks: total, fingerprint: fingerprint)
        }
        XCTAssertTrue(ok(base))
        XCTAssertFalse(ok(base, source: "/b.ogg"),  "a different file")
        XCTAssertFalse(ok(base, model: "other"),    "a different model transcribes the same audio differently")
        XCTAssertFalse(ok(base, lang: "uk"),        "a different language pin")
        XCTAssertFalse(ok(base, lang: nil),         "Auto is not the same request as a pin")
        XCTAssertFalse(ok(base, translate: true),   "translate changes the output entirely")
        XCTAssertFalse(ok(base, len: 60),           "a different chunk length moves every boundary")
        XCTAssertFalse(ok(base, total: 5),          "a different chunk count means different audio")

        var none = base; none.done = []
        XCTAssertFalse(ok(none), "nothing done → nothing to resume; start cleanly")
        var complete = base
        complete.done = Array(repeating: .init(segments: [], text: "x", language: "ru"), count: 4)
        XCTAssertFalse(ok(complete), "already complete → a leftover or corrupt record, not a resume point")

        // Identity, not just the path. The chunk count is a two-minute-wide bucket, so a re-recording under the
        // same filename matched every other field and spliced the OLD audio's chunks into the NEW transcript.
        XCTAssertFalse(ok(base, fingerprint: SourceFingerprint(size: 999, modified: Self.fixedFingerprint.modified)),
                       "a file of a different SIZE is a different recording")
        XCTAssertFalse(ok(base, fingerprint: SourceFingerprint(size: Self.fixedFingerprint.size, modified: 42)),
                       "a file modified since the record was written is a different recording")
        XCTAssertFalse(ok(base, fingerprint: nil), "an unreadable source cannot be proven to be the same one")
        var noIdentity = base; noIdentity.sourceSize = nil; noIdentity.sourceModified = nil
        XCTAssertFalse(ok(noIdentity), "a record from before identity was stored must not be trusted")
    }

    /// A damaged record is DISCARDED, not salvaged. Unlike history, whose worst case is losing the user's
    /// archive, the worst case here is transcribing from the start again — while trusting half of a corrupt
    /// record could splice the wrong audio into a transcript.
    func testACorruptRecordIsIgnoredRatherThanTrusted() throws {
        try Data("{ this is not json".utf8).write(to: ChunkProgressStore.fileURL)
        XCTAssertNil(ChunkProgressStore.load())

        let progress = ChunkedJobProgress(sourcePath: "/a.ogg", model: "m", requestedLanguage: nil,
                                          translate: false, chunkLengthSec: 120, totalChunks: 2,
                                          audioDuration: 300,
                                          done: [.init(segments: [Segment(start: 0, end: 1, text: "hi")],
                                                       text: "hi", language: "ru")])
        ChunkProgressStore.save(progress)
        XCTAssertEqual(ChunkProgressStore.load(), progress, "a good record round-trips exactly")
        ChunkProgressStore.clear()
        XCTAssertNil(ChunkProgressStore.load())
    }

    /// A failed chunk must be RETRIED on resume, not frozen into the transcript.
    ///
    /// The catch stores a "(chunk N failed)" placeholder, and the first version of resume counted it as work
    /// done: the next run skipped it and deleted its audio unretried. So a transient failure — memory pressure,
    /// which is the very condition that precedes the jetsam this feature exists for — became a permanent hole,
    /// where before resume existed the same interruption re-ran the file and the chunk usually succeeded.
    @MainActor func testAFailedChunkIsRetriedRatherThanFrozenIntoTheTranscript() async throws {
        let src = try Self.source()
        defer { try? FileManager.default.removeItem(at: src) }
        let engine = RecordingEngine()
        let m = makeModel(chunks: 3, engine: engine)
        let print = try XCTUnwrap(SourceFingerprint(of: src))

        ChunkProgressStore.save(ChunkedJobProgress(
            sourcePath: src.path, model: m.selectedModel, requestedLanguage: "ru", translate: false,
            chunkLengthSec: AudioChunker.chunkLengthSec, totalChunks: 3, audioDuration: 45 * 60,
            sourceSize: print.size, sourceModified: print.modified,
            done: [.init(segments: [], text: "GOOD:0", language: "ru"),
                   .init(segments: [], text: "(chunk 2 failed)", language: "", failed: true)]))

        await run(m, source: src)

        XCTAssertEqual(engine.askedFor, ["chunk-1", "chunk-2"],
                       "the failed chunk 1 must be re-transcribed; only the successful chunk 0 is skipped")
        let text = try XCTUnwrap(m.history.first?.text)
        XCTAssertTrue(text.contains("GOOD:0"), "the successful chunk is still reused")
        XCTAssertFalse(text.contains("failed"), "the placeholder must not survive a successful retry")
        XCTAssertTrue(text.contains("T:chunk-1"))
    }

    /// The record holds the full TEXT of every completed chunk, so "Clear history" — which promises that
    /// transcripts are permanently deleted — has to reach it. It is not a note, so nothing did.
    @MainActor func testClearingHistoryAlsoDestroysTheResumeRecordsPlaintext() throws {
        ChunkProgressStore.save(ChunkedJobProgress(
            sourcePath: "/a.ogg", model: "m", requestedLanguage: nil, translate: false,
            chunkLengthSec: 120, totalChunks: 4, audioDuration: 600,
            done: [.init(segments: [], text: "half an hour of the user's speech", language: "ru")]))
        XCTAssertNotNil(ChunkProgressStore.load())

        AppModel(engine: FakeEngine()).clearHistory()

        XCTAssertNil(ChunkProgressStore.load(),
                     "a user who cleared their history still had minutes of transcribed speech on disk")
    }

    /// …and a record nobody came back for is dropped after a grace period rather than kept indefinitely.
    /// The grace matters: unreferenced is not unwanted, which is the same reason the import sweep waits.
    func testAnAbandonedRecordIsPrunedOnlyOnceItIsOld() throws {
        let progress = ChunkedJobProgress(sourcePath: "/a.ogg", model: "m", requestedLanguage: nil,
                                          translate: false, chunkLengthSec: 120, totalChunks: 4,
                                          audioDuration: 600,
                                          done: [.init(segments: [], text: "speech", language: "ru")])
        ChunkProgressStore.save(progress)

        ChunkProgressStore.pruneIfStale(olderThan: 604_800, now: Date())
        XCTAssertNotNil(ChunkProgressStore.load(), "a fresh record is still resumable and must be kept")

        ChunkProgressStore.pruneIfStale(olderThan: 604_800, now: Date().addingTimeInterval(700_000))
        XCTAssertNil(ChunkProgressStore.load(), "…but not forever")
    }
}
