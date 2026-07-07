import Foundation
import ParlaCore
import NaturalLanguage

// MARK: - Text embedder (Local-AI Layer P1b)
//
// Turns text into one on-device embedding vector. Graceful by contract: returns nil when the language's
// assets aren't downloaded yet, the language is unsupported, or the text is empty — the caller degrades
// silently (no semantic features) and never blocks the transcript. Sendable seam + (later) a fake double,
// mirroring `TranscribingEngine`. See `LOCAL_AI_LAYER.md` §2c.

/// Retrieval models embed a QUERY differently from a DOCUMENT (Qwen3-Embedding prepends a query instruction; e5
/// uses `query:`/`passage:` prefixes). Symmetric encoders (NLContextualEmbedding) ignore `kind`.
enum EmbedKind: Sendable { case query, document }

protocol TextEmbedder: Sendable {
    /// One pooled vector for `text` in `language`, embedded as a query or a document, or nil if unavailable. Never throws.
    func embed(_ text: String, language: String, kind: EmbedKind) async -> Embedding?

    /// Per-token contextual vectors with their ranges, in ONE model pass — the raw material `embed`
    /// mean-pools. Lets callers pool IN-CONTEXT vectors for sub-spans (e.g. keyword candidates) instead of
    /// embedding bare words out of context. Ranges index `text` exactly (caller must pass clean text). nil
    /// if embedding isn't available.
    func tokenVectors(_ text: String, language: String) async -> [(range: Range<String.Index>, vector: Embedding)]?
}

extension TextEmbedder {
    /// Back-compat default: document-side embedding (every existing extractive / "Related" call site is document-side).
    func embed(_ text: String, language: String) async -> Embedding? {
        await embed(text, language: language, kind: .document)
    }
}

/// No-op embedder: returns nil for everything. Used as the default UNDER UNIT TESTS (see `AppModel.defaultEmbedder`)
/// so a test never triggers the real `NLContextualEmbedding` model load / on-device asset download, and the
/// kicked semantic refresh stays instant + deterministic. Production always gets the real `NLEmbedder`.
struct NoopEmbedder: TextEmbedder {
    func embed(_ text: String, language: String, kind: EmbedKind) async -> Embedding? { nil }
    func tokenVectors(_ text: String, language: String) async -> [(range: Range<String.Index>, vector: Embedding)]? { nil }
}

/// Real `NLContextualEmbedding` backend (macOS 14+). The Cyrillic script-model covers RU + UK and English
/// has its own — so this serves Parla's core languages on the full floor with NO LLM download (the model
/// assets download on first use). Loaded models are kept actor-internal (never cross isolation) per the
/// blueprint's concurrency rule. The live asset-download + compute path is manual-verify (not headless).
actor NLEmbedder: TextEmbedder {
    private var models: [String: NLContextualEmbedding] = [:]   // cached loaded model, keyed by language subtag

    func embed(_ text: String, language: String, kind: EmbedKind) async -> Embedding? {
        // NLContextualEmbedding is SYMMETRIC — no query/document distinction — so `kind` is ignored. (That's exactly
        // why it can't do query→note search: short queries collapse. The download-tier MLXTextEmbedder is the
        // retrieval path; NLEmbedder remains the free doc↔doc "Related" + extractive producer.)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tokens = await tokenVectors(trimmed, language: language) else { return nil }
        return SemanticIndex.meanPool(tokens.map(\.vector))
    }

    /// Per-token vectors over `text` AS GIVEN (no trimming → returned ranges index the caller's exact
    /// string, so they can be intersected with NLTagger word ranges over the same string).
    func tokenVectors(_ text: String, language: String) async -> [(range: Range<String.Index>, vector: Embedding)]? {
        guard !text.isEmpty else { return nil }
        let subtag = languagePrimarySubtag(language)
        let nlLanguage = NLLanguage(subtag.isEmpty ? "und" : subtag)
        guard let model = await loadedModel(subtag: subtag, language: nlLanguage),
              let result = try? model.embeddingResult(for: text, language: nlLanguage)
        else { return nil }

        var out: [(range: Range<String.Index>, vector: Embedding)] = []
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, range in
            out.append((range, vector))
            return true
        }
        return out
    }

    /// Get-or-load the model for a language: create → ensure assets (request on demand) → load into memory.
    /// nil at any failed step → the caller treats embedding as unavailable and degrades silently.
    private func loadedModel(subtag: String, language: NLLanguage) async -> NLContextualEmbedding? {
        if let cached = models[subtag] { return cached }
        guard let model = NLContextualEmbedding(language: language) else { return nil }
        if !model.hasAvailableAssets {
            let available = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                model.requestAssets { result, _ in cont.resume(returning: result == .available) }
            }
            guard available else { return nil }
        }
        do { try model.load() } catch { return nil }
        models[subtag] = model
        return model
    }
}
