import Foundation

// FoundationModels = Backend A (Apple's on-device model), now on BOTH platforms: macOS 26 / iOS 26.
//
// This used to be walled off with `&& os(macOS)` because the iOS-26 SDK satisfies `canImport(FoundationModels)`,
// so the `@Generable` macro on `GeneratedInsights` expanded into iOS-26-only symbols
// (`GenerationSchema`/`GeneratedContent`/…) under our iOS-17 deployment floor → "only available in iOS 26.0 or
// newer". That diagnosis was right; the remedy (exclude iOS entirely) was too blunt. The correct fix is ordinary
// availability plumbing: `@available(macOS 26, iOS 26, *)` on the generated type and the code that touches it,
// with `if #available` at every entry point. Below either floor the type still exists and reports
// `.unsupportedOS`, so the app links and runs unchanged on macOS 14 / iOS 17.
//
// Worth stating plainly, because it decides how much this is worth: Apple's model covers ~16 languages and
// NONE of them are Slavic. So this backend serves Parla's ENGLISH-and-friends audience — real paying users of a
// shipped product — while Russian/Ukrainian are served by the MLX backend and the extractive path.
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Local-AI Layer seam
//
// One capability-gated seam over on-device AI backends, mirroring `TranscribingEngine`: a `Sendable`
// protocol with an injectable default on `AppModel` + a test double. The selector picks the best
// backend available for the transcript's *language* + *OS*; where nothing is available it reports a
// reason and the UI shows nothing (core transcription untouched).
//
// Two backends live behind this seam today: `FoundationModelsService` (Apple's on-device model — English and
// its ~15 siblings, macOS 26 / iOS 26) and `MLXLLMService` (Qwen, Russian/Ukrainian, opt-in download).
// The EXTRACTIVE title/summary/keywords and semantic search are NOT this service — they ride a separate
// `SemanticIndex` and work with no download at all, which is what every free user gets.

/// Which on-device backend produced an insight. Drives provenance tagging when a language can be served by more
/// than one backend — EN is FoundationModels normally, but falls back to MLX/Qwen when Apple Intelligence is off
/// (e.g. the Mac's system language is Russian). nil = unknown → the caller uses the language-based default tag.
public enum AIBackend: Sendable { case foundation, mlx }

/// The derived insights for one transcript. Transient transport (not persisted directly — the fields
/// are folded onto `TranscriptItem`); `Equatable` for cheap diffing in tests/UI.
public struct AIInsights: Sendable, Equatable {
    public var title: String
    public var summary: String
    public var actions: [ActionItem]
    /// Generative topical keywords (the GENERATIVE upgrade over the extractive keyword pass). Empty when a backend
    /// doesn't produce them → the caller keeps the extractive keywords (so an un-downloaded model = default behavior).
    public var keywords: [String] = []
    /// Which backend produced this (set by the concrete service) — for provenance tagging. nil on test/extractive paths.
    public var backend: AIBackend? = nil
}

extension String {
    /// Uppercase ONLY the first character — normalizes model-generated action items (Cyrillic-aware) so the
    /// checklist isn't a mix of "Позвонить…" and "позвонить…". Leaves the rest (e.g. "API") untouched.
    public var sentenceCased: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// Normalize a raw model keyword list: trim, drop empties, case-insensitive de-dupe (keep first), cap at 6.
public func normalizedKeywords(_ raw: [String]) -> [String] {
    var seen = Set<String>(), out: [String] = []
    for k in raw.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !k.isEmpty {
        let key = k.lowercased()
        if seen.insert(key).inserted { out.append(k) }
        if out.count == 6 { break }
    }
    return out
}

/// Why (or whether) an AI backend can serve a given transcript. The UI only shows AI affordances on
/// `.ready`; every other case degrades silently. Language-aware: the same OS can be `.ready` for `en`
/// and `.languageUnsupported` for `ru`/`uk` (FoundationModels covers ~16 languages, not Slavic).
public enum AIAvailability: Sendable, Equatable {
    case ready                 // a backend can produce insights for this language right now
    case unsupportedOS         // below the backend's OS floor (e.g. FoundationModels needs macOS 26)
    case noAppleSilicon        // device not eligible for on-device generation
    case modelUnavailable      // model present but not usable now (AI off, still downloading, …)
    case languageUnsupported   // backend doesn't cover this language (FoundationModels: ru/uk)
    case needsModelDownload    // an opt-in model (MLX/Qwen) isn't downloaded yet
}

public enum AIError: Error, Equatable {
    case notImplemented        // a backend exists but has no generation path wired
    case unavailable           // called when `availability` isn't `.ready`
}

/// The seam. `availability` is a cheap synchronous, language-aware gate; `insights` does the work; `summarize`
/// produces a longer, free-form summary (for long-note map-reduce — the brief `insights` summary is 1–3 sentences).
public protocol LocalLLMService: Sendable {
    func availability(forLanguage language: String) -> AIAvailability
    func insights(forTranscript text: String, language: String) async throws -> AIInsights
    func summarize(_ text: String, language: String) async throws -> String
}

extension LocalLLMService {
    /// Default: fall back to the brief `insights` summary, so test doubles / Noop conform unchanged. Real backends
    /// (MLX, FoundationModels) OVERRIDE this with a comprehensive-summary prompt + a higher output-token budget.
    public func summarize(_ text: String, language: String) async throws -> String {
        try await insights(forTranscript: text, language: language).summary
    }
}

// MARK: - Language helper


/// If a generated summary looks truncated (doesn't end on sentence-final punctuation — a token-cap cutoff), trim
/// it back to the last COMPLETE sentence so it never dangles mid-word ("…Трамп призвал Зелен"). No-op when it
/// already ends cleanly (incl. a closing quote/paren after the terminal). Pure + unit-tested.
public func completeSentences(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let last = t.last else { return t }
    let terminals: Set<Character> = [".", "!", "?", "…"]
    let closers: Set<Character> = ["»", "\"", "”", ")", "’", "'"]
    if terminals.contains(last) { return t }                                              // ends on a sentence boundary
    if closers.contains(last), let prev = t.dropLast().last, terminals.contains(prev) { return t }  // …».  …!"
    guard let cut = t.lastIndex(where: { terminals.contains($0) }) else { return t }      // no boundary → leave as-is
    return String(t[...cut]).trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Backend A — FoundationModels (English-first, zero-cost, macOS 26)

/// FoundationModels backend. Below the macOS-26 floor (or where the framework can't be imported) the
/// type still exists and reports `.unsupportedOS`, so the rest of the app links and runs unchanged on
/// the macOS-14 / iOS-17 floor. `insights` generates directly into a `@Generable` type (guided decoding).
public struct FoundationModelsService: LocalLLMService {
    /// A hardcoded LOWER BOUND on what Apple's model supports — a hint for callers that cannot ask the
    /// framework (below the OS floor, or with Apple Intelligence off). It is **not** a gate: Apple keeps adding
    /// languages, so any static list goes stale, and a stale list can only ever *understate* the capability.
    /// **Load-bearing for Parla: English IS supported, Russian/Ukrainian are NOT** — the reason the embedding
    /// + MLX paths exist at all.
    public static let knownSupportedLanguages: Set<String> = ["en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh"]

    /// Cheap "could Apple's model serve this language?" hint, used for provenance tagging. The live set may only
    /// WIDEN the static bound, never narrow it — narrowing is what wrongly told users their language was
    /// unsupported. The real decision is `availability(forLanguage:)`.
    public static func maySupport(language: String) -> Bool {
        let subtag = languagePrimarySubtag(language)
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *), case .available = SystemLanguageModel.default.availability,
           SystemLanguageModel.default.supportedLanguages.contains(where: { $0.languageCode?.identifier == subtag }) {
            return true
        }
        #endif
        return knownSupportedLanguages.contains(subtag)
    }

    /// The pure decision, extracted from the framework call so it can be TESTED on any machine — with or without
    /// Apple Intelligence switched on, on a CI runner that has neither.
    ///
    /// The bug this pins: `knownSupportedLanguages` used to be consulted FIRST, as a `guard`, before the model's
    /// live set. A hardcoded list can only ever *understate* what Apple supports, so every language added after
    /// that line was written (Danish, Dutch, Norwegian, Swedish, Turkish, …) was reported "unsupported" to users
    /// whose model handled it perfectly well. The live set is the ONLY source of truth here.
    public static func decide(modelAvailable: Bool,
                              liveSupportedSubtags: Set<String>,
                              language: String) -> AIAvailability {
        guard modelAvailable else { return .modelUnavailable }   // device not eligible / AI off / still downloading
        return liveSupportedSubtags.contains(languagePrimarySubtag(language)) ? .ready : .languageUnsupported
    }

    public func availability(forLanguage language: String) -> AIAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            let model = SystemLanguageModel.default
            let live = Set(model.supportedLanguages.compactMap { $0.languageCode?.identifier })
            if case .available = model.availability {
                return Self.decide(modelAvailable: true, liveSupportedSubtags: live, language: language)
            }
            return Self.decide(modelAvailable: false, liveSupportedSubtags: live, language: language)
        }
        #endif
        return .unsupportedOS
    }

    /// Chars fed to the model in one pass — comfortably inside the ~4096-token session budget for a typical
    /// voice note. A transcript longer than this is truncated (and retried tighter on a context-window error);
    /// full per-chapter map-reduce for long recordings is a later refinement (P2d/P4).
    public static let maxInputChars = 8000
    /// Output cap so a title/summary can't run away (the @Guide prose steers length, this bounds it hard).
    public static let maxResponseTokens = 500
    /// Higher cap for the comprehensive `summarize` (long-note map-reduce) — it intentionally produces more. Generous
    /// so a long recording's summary FINISHES; `completeSentences` is the safety net if an even longer note hits it.
    public static let maxSummaryTokens = 3000

    /// Comprehensive free-form summary prompt (NOT the terse 1–3-sentence `instructions`) — for long-note map-reduce.
    public static let summaryInstructions = """
    You write a thorough, well-structured summary of a long transcript or of a set of chapter summaries. Cover ALL the \
    major topics, arguments and key points — be comprehensive, not terse (several sentences to a few short paragraphs, \
    scaled to the content). Respond in the SAME language as the input. Output ONLY the summary text — no preamble, no \
    headings, no JSON.
    """

    public static let instructions = """
    You extract a title, a short summary, topical keywords, and any action items from a voice-message transcript.
    ALWAYS respond in the SAME language as the transcript. Keep the title to a few words; the summary to 1–3 \
    sentences. Keywords: 3–6 short topical tags (single words or short phrases), no duplicates. Action items: \
    list ONLY explicit tasks or intentions the speaker says THEY need to do. For a purely narrative, reflective, \
    or descriptive note with no real task, return an EMPTY list — never turn a past action or a general \
    statement into a task. Do not invent information.
    """

    public func insights(forTranscript text: String, language: String) async throws -> AIInsights {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            guard case .ready = availability(forLanguage: language) else { throw AIError.unavailable }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AIError.unavailable }   // nothing to summarize → don't fabricate
            do {
                return try await Self.generate(String(trimmed.prefix(Self.maxInputChars)))
            } catch let error as LanguageModelSession.GenerationError {
                // Only a context-window overflow is fixable by truncating; every other GenerationError (refusal,
                // guardrail, decoding, rate-limit, …) would just waste a second full generation → rethrow it
                // (best-effort: the caller swallows it and keeps the extractive fallback).
                guard case .exceededContextWindowSize = error else { throw error }
                return try await Self.generate(String(trimmed.prefix(Self.maxInputChars / 2)))
            }
        }
        #endif
        throw AIError.unavailable
    }

    /// Comprehensive free-form summary (long-note map-reduce). Plain (non-guided) generation with a higher token cap.
    public func summarize(_ text: String, language: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            guard case .ready = availability(forLanguage: language) else { throw AIError.unavailable }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw AIError.unavailable }
            let response = try await LanguageModelSession(instructions: Self.summaryInstructions)
                .respond(to: String(trimmed.prefix(Self.maxInputChars)),
                         options: GenerationOptions(maximumResponseTokens: Self.maxSummaryTokens))
            return completeSentences(response.content)   // never dangle if the cap is hit
        }
        #endif
        throw AIError.unavailable
    }

    #if canImport(FoundationModels)
    @available(macOS 26, iOS 26, *)
    private static func generate(_ text: String) async throws -> AIInsights {
        let response = try await LanguageModelSession(instructions: instructions)
            .respond(to: text, generating: GeneratedInsights.self, options: GenerationOptions(maximumResponseTokens: maxResponseTokens))
        return response.content.asInsights
    }
    #endif
}

#if canImport(FoundationModels)
/// Guided-decoding output type: the framework generates DIRECTLY into this struct (no parsing/regex), which is
/// FoundationModels' headline feature. `@Guide` steers each field. Mapped to the backend-neutral `AIInsights`.
@available(macOS 26, iOS 26, *)
@Generable
public struct GeneratedInsights {
    @Guide(description: "A concise title for the note — at most about six words, in the SAME language as the transcript")
    public var title: String
    @Guide(description: "A 1–3 sentence summary of the key points, in the same language as the transcript")
    public var summary: String
    @Guide(description: "3–6 short topical keywords (single words or short phrases), no duplicates, in the same language as the transcript")
    public var keywords: [String]
    @Guide(description: "ONLY explicit tasks/intentions the speaker says they need to do; an EMPTY list for a narrative/reflective note with no real task — never a past action or general statement")
    public var actions: [String]

    public var asInsights: AIInsights {
        AIInsights(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            actions: actions
                .map { ActionItem(text: $0.trimmingCharacters(in: .whitespacesAndNewlines).sentenceCased) }
                .filter { !$0.text.isEmpty },
            keywords: normalizedKeywords(keywords),
            backend: .foundation
        )
    }
}
#endif

// MARK: - No-op backend (unit tests)

/// Reports no generative backend and never generates. The default `ai` under unit tests (see
/// `AppModel.defaultAI`) so a test never calls the real on-device model; the wiring is exercised with a fake.
public struct NoopAIService: LocalLLMService {
    public func availability(forLanguage language: String) -> AIAvailability { .modelUnavailable }
    public func insights(forTranscript text: String, language: String) async throws -> AIInsights { throw AIError.unavailable }
}

// MARK: - Selector — DefaultAIService

/// Production backend selector + the injectable default on `AppModel`. Picks the best backend for the
/// transcript's language: Apple's model first (it needs no download and is free), falling through to
/// MLX/Qwen when Apple can't serve the language — which is the normal case for Russian and Ukrainian,
/// since Apple Intelligence covers no Slavic language. If neither is ready the caller shows nothing and the
/// extractive path from `SemanticIndex` still stands on its own.
public struct DefaultAIService: LocalLLMService {
    private let foundationModels = FoundationModelsService()
    private let mlx = MLXLLMService()   // Backend B: RU/UK generative, opt-in download (macOS-14 floor)

    public func availability(forLanguage language: String) -> AIAvailability {
        let a = foundationModels.availability(forLanguage: language)
        if case .ready = a { return a }                 // English & co. on macOS 26 with AI on
        let b = mlx.availability(forLanguage: language)
        if case .ready = b { return b }                 // RU/UK once the MLX model is downloaded
        // Neither ready: prefer the actionable MLX reason (".needsModelDownload" → the UI can offer the download
        // for ru/uk); otherwise keep FoundationModels' reason (.unsupportedOS / .languageUnsupported / …).
        if case .needsModelDownload = b { return b }
        return a
    }

    public func insights(forTranscript text: String, language: String) async throws -> AIInsights {
        if case .ready = foundationModels.availability(forLanguage: language) {
            return try await foundationModels.insights(forTranscript: text, language: language)
        }
        if case .ready = mlx.availability(forLanguage: language) {
            return try await mlx.insights(forTranscript: text, language: language)
        }
        throw AIError.unavailable
    }

    public func summarize(_ text: String, language: String) async throws -> String {
        if case .ready = foundationModels.availability(forLanguage: language) {
            return try await foundationModels.summarize(text, language: language)
        }
        if case .ready = mlx.availability(forLanguage: language) {
            return try await mlx.summarize(text, language: language)
        }
        throw AIError.unavailable
    }
}
