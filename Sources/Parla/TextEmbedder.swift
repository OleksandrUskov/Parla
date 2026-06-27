import Foundation
import NaturalLanguage

// MARK: - Text embedder (Local-AI Layer P1b)
//
// Turns text into one on-device embedding vector. Graceful by contract: returns nil when the language's
// assets aren't downloaded yet, the language is unsupported, or the text is empty — the caller degrades
// silently (no semantic features) and never blocks the transcript. Sendable seam + (later) a fake double,
// mirroring `TranscribingEngine`. See `LOCAL_AI_LAYER.md` §2c.

protocol TextEmbedder: Sendable {
    /// One pooled vector for `text` in `language`, or nil if embedding isn't available. Never throws.
    func embed(_ text: String, language: String) async -> Embedding?
}

/// Real `NLContextualEmbedding` backend (macOS 14+). The Cyrillic script-model covers RU + UK and English
/// has its own — so this serves Parla's core languages on the full floor with NO LLM download (the model
/// assets download on first use). Loaded models are kept actor-internal (never cross isolation) per the
/// blueprint's concurrency rule. The live asset-download + compute path is manual-verify (not headless).
actor NLEmbedder: TextEmbedder {
    private var models: [String: NLContextualEmbedding] = [:]   // cached loaded model, keyed by language subtag

    func embed(_ text: String, language: String) async -> Embedding? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let subtag = languagePrimarySubtag(language)
        let nlLanguage = NLLanguage(subtag.isEmpty ? "und" : subtag)
        guard let model = await loadedModel(subtag: subtag, language: nlLanguage),
              let result = try? model.embeddingResult(for: trimmed, language: nlLanguage)
        else { return nil }

        var vectors: [[Double]] = []
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            vectors.append(vector)
            return true
        }
        return SemanticIndex.meanPool(vectors)
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
