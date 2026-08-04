import XCTest
@testable import ParlaCore

/// A long recording used to be decoded TWICE: once in full to an intermediate WAV, then that WAV was re-read to
/// cut every chunk. Two full passes, and at peak the intermediate plus all the chunks sat on disk together —
/// gigabytes for a multi-hour file, on exactly the feature Pro is sold for. Nothing in the suite would have
/// noticed, because the output was correct either way; only the cost was wrong.
///
/// This counts the decoder calls, so the regression is caught by shape rather than by someone re-reading the code.
///
/// NOTE: every model here is built with an explicit `NoopEmbedder`. `handleDrop` kicks off `refreshSemanticIndex`
/// as a fire-and-forget task, and the DEFAULT embedder picks the MLX one whenever the download-tier model happens
/// to be present on the machine — which then reaches for a Metal library `swift test` does not build, and aborts
/// the whole test process from a background task, at a different point every run.
final class NoDoubleDecodeTests: ParlaTestCase {

    /// Counts what the pipeline asks of the decoder. Returns real (tiny) WAVs so the flow can continue.
    private final class CountingDecoder: AudioDecoding, @unchecked Sendable {
        private(set) var fullDecodes = 0
        private(set) var splits = 0
        var isChunkingAvailable: Bool { true }

        func decodeToWav16k(_ src: URL) throws -> URL {
            fullDecodes += 1
            return try Self.silentWav(seconds: 1)
        }
        func splitIntoChunks(_ src: URL, chunkLength: Double) throws -> [URL] {
            splits += 1
            return [try Self.silentWav(seconds: 1)]
        }
        func renderPlayableM4a(from src: URL, to dest: URL) throws { throw AudioDecodingError.noDecoderAvailable }
        func renderPlayableWav(from src: URL, to dest: URL) throws { throw AudioDecodingError.noDecoderAvailable }

        static func silentWav(seconds: Double) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("dd-\(UUID().uuidString).wav")
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let frames = AVAudioFrameCount(seconds * 16_000)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            try file.write(from: buffer)
            return url
        }
    }

    /// A source the pipeline must DECODE. A `.wav` would be handed straight to the engine (it is in
    /// `avDecodable`), so the decoder would never be called and the test would prove nothing.
    private static func sourceNeedingDecode() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("src-\(UUID().uuidString).ogg")
        try Data("OggS\u{01}\u{00}".utf8).write(to: url)
        return url
    }

    /// Point the history store at a throwaway file. The real `history.json` is the user's data and a test that
    /// writes to it is a bug, not a test — this project has already been bitten by exactly that.
    @MainActor
    private func withIsolatedHistory(_ body: @MainActor () async -> Void) async {
        let original = HistoryStore.fileURL
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ParlaTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        HistoryStore.fileURL = dir.appendingPathComponent("history.json")
        defer { HistoryStore.fileURL = original; try? FileManager.default.removeItem(at: dir) }
        await body()
    }

    /// THE regression. A source long enough to chunk must go STRAIGHT to the chunker — the intermediate full
    /// decode never needed to exist, because the chunker reads the original container itself.
    @MainActor func testALongSourceIsNeverFullyDecodedBeforeChunking() async {
        await withIsolatedHistory {
            let counting = CountingDecoder()
            let m = AppModel(engine: FakeEngineForDecode(), ai: NoopAIService(), embedder: NoopEmbedder())
            m.decoder = counting
            m.isProUser = { true }                                  // length gate is not what is under test
            m.mediaDuration = { _ in 45 * 60 }                      // 45 minutes → well past the chunking threshold

            let src = try! Self.sourceNeedingDecode()                // .ogg → routes through the decoder, not straight to the engine
            defer { try? FileManager.default.removeItem(at: src) }
            m.handleDrop(urls: [src])
            await m.currentTranscriptionTask?.value      // handleDrop only ENQUEUES; the work runs in a task

            XCTAssertEqual(counting.splits, 1, "a long source must be chunked")
            XCTAssertEqual(counting.fullDecodes, 0,
                           "…and must NOT also be decoded in full first — that was two passes and double the disk")
        }
    }

    /// The other half: a SHORT file must still take the plain single-pass decode and must not be chunked.
    @MainActor func testAShortSourceStillTakesTheSinglePassDecode() async {
        await withIsolatedHistory {
            let counting = CountingDecoder()
            let m = AppModel(engine: FakeEngineForDecode(), ai: NoopAIService(), embedder: NoopEmbedder())
            m.decoder = counting
            m.isProUser = { true }
            m.mediaDuration = { _ in 30 }                           // 30 s

            let src = try! Self.sourceNeedingDecode()
            defer { try? FileManager.default.removeItem(at: src) }
            m.handleDrop(urls: [src])
            await m.currentTranscriptionTask?.value      // handleDrop only ENQUEUES; the work runs in a task

            XCTAssertEqual(counting.splits, 0, "a short note must not go down the chunked path")
            XCTAssertEqual(counting.fullDecodes, 1)
        }
    }

    /// When the source length cannot be determined the old behaviour must survive — decode, measure the decoded
    /// audio, and chunk from there. "Unknown duration" must not silently cost a user the long-audio path.
    @MainActor func testAnUnknownSourceDurationFallsBackToDecodingFirst() async {
        await withIsolatedHistory {
            let counting = CountingDecoder()
            let m = AppModel(engine: FakeEngineForDecode(), ai: NoopAIService(), embedder: NoopEmbedder())
            m.decoder = counting
            m.isProUser = { true }
            m.mediaDuration = { _ in nil }                          // probe cannot tell

            let src = try! Self.sourceNeedingDecode()
            defer { try? FileManager.default.removeItem(at: src) }
            m.handleDrop(urls: [src])
            await m.currentTranscriptionTask?.value      // handleDrop only ENQUEUES; the work runs in a task

            XCTAssertEqual(counting.fullDecodes, 1, "unknown length → decode first, exactly as before")
        }
    }
}

import AVFoundation

/// Minimal engine: the decode path is what is under test, not transcription.
private struct FakeEngineForDecode: TranscribingEngine {
    func ensureLoaded(model: String, progress: @Sendable @escaping (ModelLoad) -> Void) async throws {}
    func transcribe(wavPath: String, language: String?, model: String, translate: Bool) async throws -> EngineResult {
        EngineResult(text: "ok", language: "ru", segments: [], duration: 1)
    }
    func transcribe(samples: [Float], language: String?, model: String) async throws -> EngineResult {
        EngineResult(text: "ok", language: "ru", segments: [], duration: 1)
    }
    func deleteModel(_ name: String) async throws {}
}
