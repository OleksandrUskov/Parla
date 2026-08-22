import XCTest
import os
import AVFoundation
import AppKit
@testable import ParlaCore
@testable import Parla

/// Test doubles shared by the pure-logic suites. Internal (not file-private) since the suites
/// they serve now live in separate files.

/// Test helper: a Sendable box so a Task can be handed its own handle (for a self-cancelling test).
final class TaskBox: @unchecked Sendable { var task: Task<Void, Never>? }

/// Fake `TranscribingEngine`: returns canned results (or throws), counting calls. Single-flight in
/// tests (each engine call is awaited in turn), so the unchecked Sendable is safe.
final class FakeEngine: TranscribingEngine, @unchecked Sendable {
    private let results: [EngineResult]
    private let throwOnTranscribe: Bool
    private var idx = 0
    private(set) var ensureLoadedCalls = 0
    private(set) var transcribeCalls = 0
    private(set) var transcribedPaths: [String] = []   // the decode path handed to each transcribe call
    private(set) var transcribedSampleCounts: [Int] = []   // buffer sizes handed to the streaming seam
    private(set) var deletedModels: [String] = []
    private(set) var unloadCalls = 0
    var onTranscribe: (@Sendable (Int) -> Void)? = nil   // test hook: fired with the 1-based transcribe-call count (mid-decode)

    func unload() async { unloadCalls += 1 }

    init(results: [EngineResult] = [], throwOnTranscribe: Bool = false) {
        self.results = results
        self.throwOnTranscribe = throwOnTranscribe
    }

    func ensureLoaded(model: String, progress: @Sendable @escaping (ModelLoad) -> Void) async throws {
        ensureLoadedCalls += 1
    }

    func transcribe(wavPath: String, language: String?, model: String, translate: Bool) async throws -> EngineResult {
        transcribeCalls += 1
        transcribedPaths.append(wavPath)
        onTranscribe?(transcribeCalls)   // let a test cancel the enclosing task mid-decode
        if throwOnTranscribe { throw EngineError.notLoaded }
        let r = results.isEmpty ? EngineResult(text: "", language: "", segments: [], duration: 0)
                                : results[min(idx, results.count - 1)]
        idx += 1
        return r
    }

    func transcribe(samples: [Float], language: String?, model: String) async throws -> EngineResult {
        transcribeCalls += 1
        transcribedSampleCounts.append(samples.count)
        if throwOnTranscribe { throw EngineError.notLoaded }
        // Streaming windows pop the SAME canned queue as the file path, so a P3c orchestrator test can
        // hand each tick its own scripted EngineResult.
        let r = results.isEmpty ? EngineResult(text: "", language: "", segments: [], duration: 0)
                                : results[min(idx, results.count - 1)]
        idx += 1
        return r
    }

    func deleteModel(_ name: String) async throws { deletedModels.append(name) }
}

// MARK: - Test double for the AudioDecoding seam

/// Fake `AudioDecoding`: closures stand in for the ffmpeg subprocess so a test can script the decode
/// (return a sentinel path, or throw) without touching ffmpeg. Defaults are inert (passthrough / no chunking).
struct ClosureAudioDecoder: AudioDecoding {
    var decode: @Sendable (URL) throws -> URL = { $0 }
    var split: @Sendable (URL, Double) throws -> [URL] = { _, _ in [] }
    var chunkingAvailable = false
    var render: @Sendable (URL, URL) throws -> Void = { _, _ in throw AudioDecodingError.noDecoderAvailable }
    func decodeToWav16k(_ src: URL) throws -> URL { try decode(src) }
    func splitIntoChunks(_ src: URL, chunkLength: Double) throws -> [URL] { try split(src, chunkLength) }
    var isChunkingAvailable: Bool { chunkingAvailable }
    func renderPlayableM4a(from src: URL, to dest: URL) throws { try render(src, dest) }
    func renderPlayableWav(from src: URL, to dest: URL) throws { try render(src, dest) }
}

// MARK: - Test double for the Local-AI seam

/// Fake `LocalLLMService`: reports a fixed availability and returns canned insights (or throws).
/// Value type → trivially Sendable, like the seam it stands in for.
struct FakeAIService: LocalLLMService {
    var availabilityToReturn: AIAvailability = .ready
    var canned: AIInsights = AIInsights(title: "T", summary: "S", actions: [])
    var error: AIError? = nil   // when set, insights throws it — exercises the AI-failure-non-fatal invariant

    func availability(forLanguage language: String) -> AIAvailability { availabilityToReturn }
    func insights(forTranscript text: String, language: String) async throws -> AIInsights {
        if let error { throw error }
        return canned
    }
}

/// AI double that throws ONLY for inputs containing `failMarker` — to prove per-chapter best-effort
/// (one chapter fails, the others still get summaries). Always `.ready`.
struct PerChapterAIService: LocalLLMService {
    let failMarker: String
    func availability(forLanguage language: String) -> AIAvailability { .ready }
    func insights(forTranscript text: String, language: String) async throws -> AIInsights {
        if text.contains(failMarker) { throw AIError.unavailable }
        return AIInsights(title: "T", summary: "ok", actions: [])
    }
}

/// AI double for the map→reduce test: the REDUCE input is the chapter summaries joined by NEWLINES (multi-line),
/// while each per-CHAPTER input is a single space-joined line → distinguish by the newline to return distinct results.
struct ReduceAIService: LocalLLMService {
    func availability(forLanguage language: String) -> AIAvailability { .ready }
    /// The whole-recording digest. It is what the overall `insights` call is now handed, which is also how
    /// this double tells the two kinds of call apart.
    func summarize(_ text: String, language: String) async throws -> String { "OVERALL" }
    func insights(forTranscript text: String, language: String) async throws -> AIInsights {
        // Re-pointed when the title and keywords moved onto the hierarchical summary. This used to branch on
        // "does the input contain a newline", which distinguished the joined chapter summaries from a single
        // chapter's text — a heuristic that stopped meaning anything once the overall call receives a reduce
        // OUTPUT rather than a join. The discriminator is now the digest itself.
        text == "OVERALL"
            ? AIInsights(title: "OverallТ", summary: "OVERALL", actions: [], keywords: ["ovk"])
            : AIInsights(title: "chT", summary: "chS", actions: [], keywords: [])
    }
}

/// AI double where the brief `insights` summary ("BRIEF") differs from the detailed `summarize` ("DETAILED…") —
/// proves the long-note summary path uses `summarize`, not the terse `insights`.
struct DetailedSummaryAIService: LocalLLMService {
    func availability(forLanguage language: String) -> AIAvailability { .ready }
    func insights(forTranscript text: String, language: String) async throws -> AIInsights {
        AIInsights(title: "T", summary: "BRIEF", actions: [], keywords: ["k"])
    }
    func summarize(_ text: String, language: String) async throws -> String { "DETAILED whole-recording summary" }
}

/// Records the text handed to `insights`, so a test can assert WHICH text the title and keywords were derived
/// from — the thing that separates "the title describes the whole recording" from "the title describes its
/// first eight thousand characters". Single-flight in tests → unchecked Sendable, same as the others here.
final class InsightsInputSpy: LocalLLMService, @unchecked Sendable {
    private(set) var insightsInputs: [String] = []
    let summaryText: String
    init(summaryText: String = "WHOLE-RECORDING SUMMARY") { self.summaryText = summaryText }
    func availability(forLanguage language: String) -> AIAvailability { .ready }
    func insights(forTranscript text: String, language: String) async throws -> AIInsights {
        insightsInputs.append(text)
        return AIInsights(title: "T", summary: "BRIEF", actions: [], keywords: ["k"])
    }
    func summarize(_ text: String, language: String) async throws -> String { summaryText }
}

/// Counts `summarize` calls — to prove the hierarchical reduce BATCHES + RECURSES on over-budget input (many calls)
/// vs a single pass when it fits. Single-flight in tests → unchecked Sendable is safe (same as FakeEngine).
final class CountingSummaryAIService: LocalLLMService, @unchecked Sendable {
    private(set) var summarizeCalls = 0
    func availability(forLanguage language: String) -> AIAvailability { .ready }
    func insights(forTranscript text: String, language: String) async throws -> AIInsights {
        AIInsights(title: "T", summary: "S", actions: [])
    }
    func summarize(_ text: String, language: String) async throws -> String { summarizeCalls += 1; return "SUM" }
}

/// Fake `TextEmbedder`: returns a canned vector (or nil) and counts calls. Single-flight in tests
/// (each embed is awaited in turn), so the unchecked Sendable is safe — same pattern as FakeEngine.
final class FakeEmbedder: TextEmbedder, @unchecked Sendable {
    private let vector: Embedding?
    private(set) var calls = 0
    init(vector: Embedding? = [1, 0, 0]) { self.vector = vector }
    func embed(_ text: String, language: String, kind: EmbedKind) async -> Embedding? { calls += 1; return vector }
    func tokenVectors(_ text: String, language: String) async -> [(range: Range<String.Index>, vector: Embedding)]? {
        guard let vector, !text.isEmpty else { return vector == nil ? nil : [] }
        return [(text.startIndex..<text.endIndex, vector)]   // one token spanning the whole string
    }
}

/// Embedder that (a) returns a text-dependent vector so a test can tell which text was embedded, and
/// (b) runs an injected hook DURING embed — to deterministically reproduce an edit landing mid-embed.
final class HookEmbedder: TextEmbedder, @unchecked Sendable {
    var hook: (@MainActor @Sendable () -> Void)?
    private func vec(_ text: String) -> Embedding { text.contains("новый") ? [0, 1] : [1, 0] }
    func embed(_ text: String, language: String, kind: EmbedKind) async -> Embedding? {
        if let hook { await MainActor.run { hook() } }   // main actor is free (caller is awaiting us)
        return vec(text)
    }
    func tokenVectors(_ text: String, language: String) async -> [(range: Range<String.Index>, vector: Embedding)]? {
        text.isEmpty ? nil : [(text.startIndex..<text.endIndex, vec(text))]
    }
}

