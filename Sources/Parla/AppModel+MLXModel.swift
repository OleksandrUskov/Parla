import Foundation

/// MLX RU/UK generative model (AI P3): opt-in download / delete / on-disk state — parallel to, and independent
/// of, the WhisperKit transcription catalog (`AppModel+Models.swift`). Downloading the model IS the opt-in:
/// once present, `MLXLLMService` reports `.ready` for ru/uk and `enrichInsights` upgrades those notes.
extension AppModel {
    /// Refresh the cached on-disk state (presence + size). Cheap presence check on main; size walk off-main.
    func refreshMLXModelState() {
        mlxModelDownloaded = MLXModelSpec.isDownloaded()
        let present = mlxModelDownloaded
        Task {   // @MainActor task; heavy size walk detached, assigned back on main
            let bytes = present ? await Task.detached { MLXModelSpec.bytesOnDisk() }.value : 0
            self.mlxModelBytes = bytes
        }
    }

    /// Opt-in download of the RU/UK generative model (~2.3 GB) from Hugging Face's public (non-gated) CDN — the
    /// same in-app UX as the Whisper models, no browser/account. On success, kicks a semantic refresh so existing
    /// RU/UK notes get generative insights. Holds the lane through that refresh (the model load is memory-heavy —
    /// don't let a transcription start alongside it). Best-effort: a failure surfaces a transient error and keeps
    /// everything extractive.
    func downloadMLXModel() async {
        guard !isBusy, downloadingModel == nil, !mlxDownloading, !mlxModelDownloaded else { return }
        mlxDownloading = true
        mlxDownloadProgress = 0
        defer { mlxDownloading = false }   // released only after the post-download enrich (lane held throughout)
        do {
            try await MLXEngine.shared.downloadModel(progressHandler: { @Sendable [weak self] p in
                // @Sendable: crosses into HubApi's nonisolated download. `self` (@MainActor → Sendable) is
                // touched only inside the @MainActor hop. Mirrors the WhisperKit download callback.
                Task { @MainActor in self?.mlxDownloadProgress = p.fractionCompleted }
            })
        } catch {
            phase = .failed(Lf("error.mlx.download", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            return
        }
        refreshMLXModelState()
        await refreshSemanticIndex()   // RU/UK items now reach `.ready` → enrich upgrades them to generative
    }

    /// Delete the downloaded RU/UK model + drop it from memory (frees the disk + RAM). Recomputes the size line.
    func deleteMLXModel() async {
        guard !isBusy, downloadingModel == nil, !mlxDownloading else { return }
        try? FileManager.default.removeItem(at: MLXModelSpec.modelDirectory())
        await MLXEngine.shared.unload()
        refreshMLXModelState()
    }
}
