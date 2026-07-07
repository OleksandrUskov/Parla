import Foundation

/// MLX RU/UK generative model (AI P3): opt-in download / delete / on-disk state — parallel to, and independent
/// of, the WhisperKit transcription catalog (`AppModel+Models.swift`). Downloading the model IS the opt-in:
/// once present, `MLXLLMService` reports `.ready` for ru/uk and `enrichInsights` upgrades those notes.
extension AppModel {
    /// Refresh the cached on-disk state (presence + size). Cheap presence check on main; size walk off-main.
    public func refreshMLXModelState() {
        mlxModelDownloaded = MLXModelSpec.isDownloaded()
        let present = mlxModelDownloaded
        Task {   // @MainActor task; heavy size walk detached, assigned back on main
            let bytes = present ? await Task.detached { MLXModelSpec.bytesOnDisk() }.value : 0
            self.mlxModelBytes = bytes
        }
    }

    /// Opt-in download of the RU/UK generative model (~2.3 GB) from Hugging Face's public (non-gated) CDN — the
    /// same in-app UX as the Whisper models, no browser/account. On success it kicks a BACKGROUND semantic refresh
    /// so existing RU/UK notes get generative insights — WITHOUT holding the lane: the refresh is best-effort and
    /// must not freeze the UI (the progress bar) or block transcription for minutes while it loads the model and
    /// generates per note. Memory is bounded by the engine's GPU-cache cap + the post-batch model unload. A failure
    /// surfaces inline (mlxDownloadError) + as a transient chip, and keeps everything extractive.
    public func downloadMLXModel() async {
        guard !isBusy, downloadingModel == nil, !mlxDownloading, !mlxModelDownloaded else { return }
        mlxDownloading = true
        mlxDownloadProgress = 0
        mlxDownloadError = nil
        do {
            try await MLXEngine.shared.downloadModel(progressHandler: { @Sendable [weak self] p in
                // @Sendable: crosses into HubApi's nonisolated download. `self` (@MainActor → Sendable) is
                // touched only inside the @MainActor hop. Mirrors the WhisperKit download callback.
                Task { @MainActor in self?.mlxDownloadProgress = p.fractionCompleted }
            })
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            mlxDownloadError = msg
            phase = .failed(Lf("error.mlx.download", msg))
            mlxDownloading = false
            return
        }
        mlxDownloading = false
        refreshMLXModelState()
        Task { await refreshSemanticIndex() }   // background enrich: lane released; memory bounded by cacheLimit + post-batch unload
    }

    /// Delete the downloaded RU/UK model + drop it from memory (frees the disk + RAM). Recomputes the size line.
    public func deleteMLXModel() async {
        guard !isBusy, downloadingModel == nil, !mlxDownloading else { return }
        try? FileManager.default.removeItem(at: MLXModelSpec.modelDirectory())
        await MLXEngine.shared.unload()
        refreshMLXModelState()
    }
}
