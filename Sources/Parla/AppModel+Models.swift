import Foundation
@preconcurrency import WhisperKit   // not Sendable-annotated yet — see TranscriptionEngine.swift

/// Model catalog: download status / on-disk size, download/delete, tiers for the manager.
extension AppModel {
    // MARK: Status / on-disk size

    func isDownloaded(_ model: String) -> Bool { downloadedSet.contains(model) }
    var totalModelsBytes: Int64 { modelSizes.values.reduce(0, +) }

    /// Cheap presence check on the main thread; the heavy size walk runs in the background.
    func refreshDownloaded() {
        let models = Set(availableModels + [selectedModel])
        var set = Set<String>()
        for m in models where TranscriptionEngine.isDownloaded(m) { set.insert(m) }
        downloadedSet = set
        let toSize = set
        Task {   // @MainActor task; run the heavy walk detached and assign back on main
            let sizes = await Task.detached { () -> [String: Int64] in
                var s: [String: Int64] = [:]
                for m in toSize { s[m] = TranscriptionEngine.modelSize(m) }
                return s
            }.value
            self.modelSizes = sizes
        }
    }

    func refreshModels() async {
        let support = await WhisperKit.recommendedRemoteModels()
        let models = support.supported.sorted()
        guard !models.isEmpty else { return }
        availableModels = models
        // Don't override the user's choice if the model is already downloaded (even if it's not in the recommended list).
        if !models.contains(selectedModel), !TranscriptionEngine.isDownloaded(selectedModel) {
            selectedModel = Self.bestDefault(from: models)
        }
        refreshDownloaded()
    }

    func downloadModel(_ name: String) async {
        guard !isBusy, downloadingModel == nil, !isDownloaded(name) else { return }
        downloadingModel = name
        downloadProgress = 0
        do {
            _ = try await WhisperKit.download(variant: name, progressCallback: { @Sendable [weak self] p in
                // @Sendable: the callback crosses into WhisperKit's nonisolated download. `self`
                // (a @MainActor class → Sendable) is touched only inside the @MainActor Task hop.
                Task { @MainActor in self?.downloadProgress = p.fractionCompleted }
            })
        } catch {
            phase = .failed(Lf("error.model.download", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
        downloadingModel = nil
        refreshDownloaded()
    }

    func deleteModel(_ name: String) async {
        guard !isBusy, downloadingModel == nil else { return }
        do {
            try await engine.deleteModel(name)
            refreshDownloaded()
        } catch {
            phase = .failed(Lf("error.model.delete", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }

    // MARK: Model tiers (for the manager)

    /// Clean list of 5 tiers (one variant per tier), without quantized clones.
    var modelTiers: [ModelTier] {
        func pick(_ cands: [String]) -> String? {
            cands.first(where: { availableModels.contains($0) })
                ?? cands.first(where: { c in availableModels.contains(where: { $0.hasPrefix(c) }) })
        }
        var tiers: [ModelTier] = []
        func add(_ title: String, _ hint: String, _ estimate: String, _ cands: [String], rec: Bool = false) {
            if let n = pick(cands) {
                tiers.append(ModelTier(title: title, hint: hint, estimate: estimate, name: n, recommended: rec))
            }
        }
        add("Tiny", L("model.tier.tiny.hint"), L("model.size.tiny"), ["openai_whisper-tiny"])
        add("Base", L("model.tier.base.hint"), L("model.size.base"), ["openai_whisper-base"])
        add("Small", L("model.tier.small.hint"), L("model.size.small"), ["openai_whisper-small"])
        add("Large v3 turbo", L("model.tier.turbo.hint"), L("model.size.turbo"),
            ["openai_whisper-large-v3-v20240930_626MB",
             "openai_whisper-large-v3-v20240930",
             "openai_whisper-large-v3-v20240930_turbo_632MB",
             "openai_whisper-large-v3-v20240930_turbo"], rec: true)
        add("Large v3", L("model.tier.large.hint"), L("model.size.large"),
            ["openai_whisper-large-v3", "openai_whisper-large-v3_947MB"])
        if !tiers.contains(where: { $0.name == selectedModel }) {
            tiers.append(ModelTier(title: friendlyModel(selectedModel), hint: L("model.current.hint"),
                                   estimate: "", name: selectedModel, recommended: false))
        }
        return tiers
    }

    nonisolated static func bestDefault(from models: [String]) -> String {
        // Prefer the quantized 626MB turbo: measured best quality-per-size on RU + smallest "large" download
        // (the full-precision 1.5GB variant decoded WORSE on real RU; full large-v3 worse still). Falls back to
        // any large-v3-v20240930 variant, then large-v3, then base.
        if let q = models.first(where: { $0 == "openai_whisper-large-v3-v20240930_626MB" }) { return q }
        if let turbo = models.first(where: { $0.contains("large-v3-v20240930") }) { return turbo }
        if let v3 = models.first(where: { $0.contains("large-v3") }) { return v3 }
        if let base = models.first(where: { $0.contains("base") && !$0.contains(".en") }) { return base }
        return models.first ?? "openai_whisper-base"
    }
}
