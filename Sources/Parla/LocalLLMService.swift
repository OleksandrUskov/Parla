import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Local-AI Layer seam (P0)
//
// One capability-gated seam over on-device AI backends, mirroring `TranscribingEngine`: a `Sendable`
// protocol with an injectable default on `AppModel` + a test double. The selector picks the best
// backend available for the transcript's *language* + *OS*; where nothing is available it reports a
// reason and the UI shows nothing (core transcription untouched).
//
// P0 ships the seam + gating only — no generation runs yet. `FoundationModelsService` (English,
// macOS 26) is wired in P2; the MLX RU/UK backend in P3; RU/UK extractive title/summary + semantic
// search ride a *separate* `SemanticIndex` (P1), not this LLM service. See
// `LOCAL_AI_LAYER.md`.

/// The derived insights for one transcript. Transient transport (not persisted directly — the fields
/// are folded onto `TranscriptItem`); `Equatable` for cheap diffing in tests/UI.
struct AIInsights: Sendable, Equatable {
    var title: String
    var summary: String
    var actions: [ActionItem]
    /// Generative topical keywords (the GENERATIVE upgrade over the extractive keyword pass). Empty when a backend
    /// doesn't produce them → the caller keeps the extractive keywords (so an un-downloaded model = default behavior).
    var keywords: [String] = []
}

extension String {
    /// Uppercase ONLY the first character — normalizes model-generated action items (Cyrillic-aware) so the
    /// checklist isn't a mix of "Позвонить…" and "позвонить…". Leaves the rest (e.g. "API") untouched.
    var sentenceCased: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// Normalize a raw model keyword list: trim, drop empties, case-insensitive de-dupe (keep first), cap at 6.
func normalizedKeywords(_ raw: [String]) -> [String] {
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
enum AIAvailability: Sendable, Equatable {
    case ready                 // a backend can produce insights for this language right now
    case unsupportedOS         // below the backend's OS floor (e.g. FoundationModels needs macOS 26)
    case noAppleSilicon        // device not eligible for on-device generation
    case modelUnavailable      // model present but not usable now (AI off, still downloading, …)
    case languageUnsupported   // backend doesn't cover this language (FoundationModels: ru/uk)
    case needsModelDownload    // an opt-in model (MLX/Qwen, P3) isn't downloaded yet
}

enum AIError: Error, Equatable {
    case notImplemented        // P0: no generation wired yet
    case unavailable           // called when `availability` isn't `.ready`
}

/// The seam. `availability` is a cheap synchronous, language-aware gate; `insights` does the work.
protocol LocalLLMService: Sendable {
    func availability(forLanguage language: String) -> AIAvailability
    func insights(forTranscript text: String, language: String) async throws -> AIInsights
}

// MARK: - Language helper

/// Primary BCP-47 subtag, lowercased: `"en-US"`/`"EN_us"` → `"en"`, `""` → `""`. Pure + testable —
/// used to match a transcript's language code against a backend's supported-language set.
func languagePrimarySubtag(_ code: String) -> String {
    code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
}

// MARK: - Backend A — FoundationModels (English-first, zero-cost, macOS 26)

/// FoundationModels backend. Below the macOS-26 floor (or where the framework can't be imported) the
/// type still exists and reports `.unsupportedOS`, so the rest of the app links and runs unchanged on
/// the macOS-14 floor. P0 implements only the gate; `insights` is wired in P2 (`@Generable` output).
struct FoundationModelsService: LocalLLMService {
    /// Cheap, language-aware pre-gate. The framework's live list
    /// (`SystemLanguageModel.supportedLanguages`, macOS 26) is the source of truth and refines this at
    /// runtime in P2; this static set is the conservative pre-gate. **Load-bearing for Parla: English
    /// IS supported, Russian/Ukrainian are NOT** — the reason the embedding + MLX paths exist at all.
    static let knownSupportedLanguages: Set<String> = ["en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh"]

    static func maySupport(language: String) -> Bool {
        knownSupportedLanguages.contains(languagePrimarySubtag(language))
    }

    func availability(forLanguage language: String) -> AIAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let subtag = languagePrimarySubtag(language)
            guard Self.maySupport(language: language) else { return .languageUnsupported }
            switch SystemLanguageModel.default.availability {
            case .available:
                // Refine the static pre-gate against the model's LIVE supported set (the source of truth): a
                // language in `knownSupportedLanguages` but not actually installed/supported must NOT reach the
                // session (avoids a guaranteed `unsupportedLanguageOrLocale` generation).
                guard SystemLanguageModel.default.supportedLanguages
                    .contains(where: { $0.languageCode?.identifier == subtag }) else { return .languageUnsupported }
                return .ready
            default: return .modelUnavailable   // device not eligible / AI off / model not ready
            }
        }
        #endif
        return .unsupportedOS
    }

    /// Chars fed to the model in one pass — comfortably inside the ~4096-token session budget for a typical
    /// voice note. A transcript longer than this is truncated (and retried tighter on a context-window error);
    /// full per-chapter map-reduce for long recordings is a later refinement (P2d/P4).
    static let maxInputChars = 8000
    /// Output cap so a title/summary can't run away (the @Guide prose steers length, this bounds it hard).
    static let maxResponseTokens = 500

    static let instructions = """
    You extract a title, a short summary, topical keywords, and any action items from a voice-message transcript.
    ALWAYS respond in the SAME language as the transcript. Keep the title to a few words; the summary to 1–3 \
    sentences. Keywords: 3–6 short topical tags (single words or short phrases), no duplicates. Action items: \
    list ONLY explicit tasks or intentions the speaker says THEY need to do. For a purely narrative, reflective, \
    or descriptive note with no real task, return an EMPTY list — never turn a past action or a general \
    statement into a task. Do not invent information.
    """

    func insights(forTranscript text: String, language: String) async throws -> AIInsights {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
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

    #if canImport(FoundationModels)
    @available(macOS 26, *)
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
@available(macOS 26, *)
@Generable
struct GeneratedInsights {
    @Guide(description: "A concise title for the note — at most about six words, in the SAME language as the transcript")
    var title: String
    @Guide(description: "A 1–3 sentence summary of the key points, in the same language as the transcript")
    var summary: String
    @Guide(description: "3–6 short topical keywords (single words or short phrases), no duplicates, in the same language as the transcript")
    var keywords: [String]
    @Guide(description: "ONLY explicit tasks/intentions the speaker says they need to do; an EMPTY list for a narrative/reflective note with no real task — never a past action or general statement")
    var actions: [String]

    var asInsights: AIInsights {
        AIInsights(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            actions: actions
                .map { ActionItem(text: $0.trimmingCharacters(in: .whitespacesAndNewlines).sentenceCased) }
                .filter { !$0.text.isEmpty },
            keywords: normalizedKeywords(keywords)
        )
    }
}
#endif

// MARK: - No-op backend (unit tests)

/// Reports no generative backend and never generates. The default `ai` under unit tests (see
/// `AppModel.defaultAI`) so a test never calls the real on-device model; the wiring is exercised with a fake.
struct NoopAIService: LocalLLMService {
    func availability(forLanguage language: String) -> AIAvailability { .modelUnavailable }
    func insights(forTranscript text: String, language: String) async throws -> AIInsights { throw AIError.unavailable }
}

// MARK: - Selector — DefaultAIService

/// Production backend selector + the injectable default on `AppModel`. Picks the best backend for the
/// transcript's language. P0: only `FoundationModelsService` (English, macOS 26) exists; the MLX RU/UK
/// backend is added in P3, at which point this falls through to it when FoundationModels can't serve
/// the language. Until then RU/UK have no *generative* backend (they get extractive insights + semantic
/// search from `SemanticIndex` in P1, not via this service).
struct DefaultAIService: LocalLLMService {
    private let foundationModels = FoundationModelsService()
    private let mlx = MLXLLMService()   // Backend B: RU/UK generative, opt-in download (macOS-14 floor)

    func availability(forLanguage language: String) -> AIAvailability {
        let a = foundationModels.availability(forLanguage: language)
        if case .ready = a { return a }                 // English & co. on macOS 26 with AI on
        let b = mlx.availability(forLanguage: language)
        if case .ready = b { return b }                 // RU/UK once the MLX model is downloaded
        // Neither ready: prefer the actionable MLX reason (".needsModelDownload" → the UI can offer the download
        // for ru/uk); otherwise keep FoundationModels' reason (.unsupportedOS / .languageUnsupported / …).
        if case .needsModelDownload = b { return b }
        return a
    }

    func insights(forTranscript text: String, language: String) async throws -> AIInsights {
        if case .ready = foundationModels.availability(forLanguage: language) {
            return try await foundationModels.insights(forTranscript: text, language: language)
        }
        if case .ready = mlx.availability(forLanguage: language) {
            return try await mlx.insights(forTranscript: text, language: language)
        }
        throw AIError.unavailable
    }
}
