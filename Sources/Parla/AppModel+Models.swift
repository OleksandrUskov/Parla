import Foundation
import WhisperKit

/// Каталог моделей: статус/размер на диске, скачивание/удаление, уровни для менеджера.
extension AppModel {
    // MARK: Статус / размер на диске

    func isDownloaded(_ model: String) -> Bool { downloadedSet.contains(model) }
    var totalModelsBytes: Int64 { modelSizes.values.reduce(0, +) }

    /// Дешёвая проверка наличия — на главном потоке; тяжёлый подсчёт размеров — в фоне.
    func refreshDownloaded() {
        let models = Set(availableModels + [selectedModel])
        var set = Set<String>()
        for m in models where TranscriptionEngine.isDownloaded(m) { set.insert(m) }
        downloadedSet = set
        let toSize = set
        Task {   // @MainActor-задача; тяжёлый walk считаем в detached и присваиваем на main
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
        // Не перебиваем выбор пользователя, если модель уже скачана (даже если её нет в рекомендованных).
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
            _ = try await WhisperKit.download(variant: name, progressCallback: { [weak self] p in
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

    // MARK: Уровни моделей (для менеджера)

    /// Чистый список из 5 уровней (по одному варианту на уровень), без квантованных клонов.
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
        if let exact = models.first(where: { $0 == "openai_whisper-large-v3-v20240930" }) { return exact }
        if let turbo = models.first(where: { $0.contains("large-v3-v20240930") }) { return turbo }
        if let v3 = models.first(where: { $0.contains("large-v3") }) { return v3 }
        if let base = models.first(where: { $0.contains("base") && !$0.contains(".en") }) { return base }
        return models.first ?? "openai_whisper-base"
    }
}
