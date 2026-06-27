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
            guard Self.maySupport(language: language) else { return .languageUnsupported }
            switch SystemLanguageModel.default.availability {
            case .available: return .ready
            default:         return .modelUnavailable   // device not eligible / AI off / model not ready
            }
        }
        #endif
        return .unsupportedOS
    }

    func insights(forTranscript text: String, language: String) async throws -> AIInsights {
        throw AIError.notImplemented   // P2 wires @Generable {title, summary, actions} guided decoding
    }
}

// MARK: - Selector — DefaultAIService

/// Production backend selector + the injectable default on `AppModel`. Picks the best backend for the
/// transcript's language. P0: only `FoundationModelsService` (English, macOS 26) exists; the MLX RU/UK
/// backend is added in P3, at which point this falls through to it when FoundationModels can't serve
/// the language. Until then RU/UK have no *generative* backend (they get extractive insights + semantic
/// search from `SemanticIndex` in P1, not via this service).
struct DefaultAIService: LocalLLMService {
    private let foundationModels = FoundationModelsService()

    func availability(forLanguage language: String) -> AIAvailability {
        foundationModels.availability(forLanguage: language)
        // P3: if the above isn't `.ready`, fall through to MLXLLMService (RU/UK, opt-in download).
    }

    func insights(forTranscript text: String, language: String) async throws -> AIInsights {
        try await foundationModels.insights(forTranscript: text, language: language)
    }
}
