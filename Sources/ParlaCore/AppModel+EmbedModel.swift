#if os(macOS)  // Embedding-model management = macOS-only; no Core caller on iOS.
import Foundation

/// Embedding model: opt-in download / delete / on-disk state for query→note SEMANTIC SEARCH — parallel
/// to the MLX generative model (`AppModel+MLXModel.swift`) and the WhisperKit catalog. Downloading it switches the
/// retrieval embedder from NLContextualEmbedding to the download-tier model; on success the whole history re-embeds
/// into the new (better, cross-lingual) space (`backfillEmbeddings`) and search goes semantic.
extension AppModel {
    /// Refresh the cached on-disk state (presence + size). Cheap presence check on main; size walk off-main.
    public func refreshEmbedModelState() {
        embedModelDownloaded = EmbeddingModelSpec.isDownloaded()
        let present = embedModelDownloaded
        Task {   // @MainActor task; heavy size walk detached, assigned back on main
            let bytes = present ? await Task.detached { EmbeddingModelSpec.bytesOnDisk() }.value : 0
            self.embedModelBytes = bytes
        }
    }

    /// Opt-in download of the semantic-search model (~0.4 GB) from Hugging Face's public (non-gated) CDN — same
    /// in-app UX as the Whisper / MLX models, no browser/account. On success it kicks a BACKGROUND semantic refresh
    /// that re-embeds the corpus into the new space and turns on query→note search — WITHOUT holding the lane (the
    /// refresh is best-effort and must not freeze the UI). A failure surfaces inline + as a transient chip, and
    /// search stays lexical.
    public func downloadEmbedModel() async {
        if aiPowerIsGated() { return }   // the semantic-search model is a Pro download
        guard !isBusy, downloadingModel == nil, !embedDownloading, !embedModelDownloaded else { return }
        embedDownloading = true
        embedDownloadProgress = 0
        embedDownloadError = nil
        do {
            try await MLXTextEmbedder.shared.downloadModel(progressHandler: { @Sendable [weak self] p in
                // @Sendable: crosses into HubApi's nonisolated download; `self` touched only inside the @MainActor hop.
                Task { @MainActor in self?.embedDownloadProgress = p.fractionCompleted }
            })
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            embedDownloadError = msg
            phase = .failed(Lf("error.embed.download", msg))
            embedDownloading = false
            return
        }
        embedDownloading = false
        refreshEmbedModelState()
        Task { await refreshSemanticIndex() }   // background: re-embed the corpus into the new space + enable semantic search
    }

    /// Delete the downloaded model + drop it from memory. Re-embeds the corpus back into the NL space (the tag
    /// switch) so "Related" + search keep working on the free embedder. Recomputes the size line.
    public func deleteEmbedModel() async {
        guard !isBusy, downloadingModel == nil, !embedDownloading else { return }
        try? FileManager.default.removeItem(at: EmbeddingModelSpec.modelDirectory())
        await MLXTextEmbedder.shared.unload()
        refreshEmbedModelState()
        Task { await refreshSemanticIndex() }   // model gone → re-embed back into the NL space
    }
}
#endif  // os(macOS) — embedding-model management
