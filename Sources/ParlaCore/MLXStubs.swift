import Foundation

#if !os(macOS)
// MARK: - iOS inert MLX stubs (iOS-port P1)
//
// The MLX generative/embedding backend is macOS-only. `Package.swift` gates the MLX products with
// `.when(platforms: [.macOS])`; `MLXLLMService.swift` / `MLXTextEmbedder.swift` / `AppModel+MLXModel.swift` /
// `AppModel+EmbedModel.swift` are `#if os(macOS)`. These inert stubs give the remaining Core consumers
// (`AppModel+Semantic`, `DefaultAIService` in `LocalLLMService.swift`) the exact symbols they reference so they
// compile UNCHANGED on iOS and the EXTRACTIVE AI path stays fully live: `EmbeddingModelSpec.isDownloaded()`
// returns `false` → `retrievalEmbedder` falls back to `NLEmbedder`; the generative backend reports unavailable.
// Nothing here loads a model or touches Metal. iOS v1 ships extractive insights + NLContextualEmbedding "Related".
//
// `#if !os(macOS)` is the exact complement of the real files' `#if os(macOS)` → EXACTLY ONE definition of each
// symbol on every platform (macOS = real, everything else = stub).

/// Inert on iOS: the download-tier embedding model is never present, so retrieval always uses `NLEmbedder`.
public struct EmbeddingModelSpec: Sendable {
    public let tag: String
    /// `EmbeddingModelSpec.active.tag` is read by the semantic-store provenance compare in `AppModel+Semantic`.
    /// The value is unreached at runtime (every use is guarded by `isDownloaded()` == false) but must resolve to compile.
    public static let active = EmbeddingModelSpec(tag: "emb:unavailable-ios")
    /// Hard `false` on iOS — LOAD-BEARING: keeps `retrievalEmbedder` on `NLEmbedder` and short-circuits every
    /// download-tier branch in `AppModel+Semantic`.
    public static func isDownloaded() -> Bool { false }
}

/// Inert on iOS: there is no MLX generative model to unload.
public actor MLXEngine {
    public static let shared = MLXEngine()
    /// No-op: nothing is loaded on iOS. Mirrors the macOS signature so the post-batch `unload()` calls compile.
    public func unload() {}
}

/// Inert on iOS: present so `retrievalEmbedder`'s type resolves, but never selected (`isDownloaded()` == false)
/// and never produces a vector. Conforms to `TextEmbedder` returning nil (graceful — callers degrade to lexical / NL).
public actor MLXTextEmbedder: TextEmbedder {
    public static let shared = MLXTextEmbedder()
    public func embed(_ text: String, language: String, kind: EmbedKind) async -> Embedding? { nil }
    public func tokenVectors(_ text: String, language: String) async -> [(range: Range<String.Index>, vector: Embedding)]? { nil }
}

/// Inert generative backend on iOS (no MLX, no Apple-Intelligence equivalent): reports unavailable, never generates.
/// Keeps `DefaultAIService` (in `LocalLLMService.swift`) compiling unchanged; on iOS its selector falls through to
/// FoundationModels' `.unsupportedOS`, so the UI shows no generative affordance and the extractive path is used.
public struct MLXLLMService: LocalLLMService {
    public init() {}
    public func availability(forLanguage language: String) -> AIAvailability { .modelUnavailable }
    public func insights(forTranscript text: String, language: String) async throws -> AIInsights { throw AIError.unavailable }
    // `summarize` uses the `LocalLLMService` default (delegates to `insights` → throws). No generative path on iOS.
}
#endif
