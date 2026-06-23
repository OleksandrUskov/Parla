import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WhisperKit

@MainActor
@Observable
final class AppModel {
    var phase: EnginePhase = .idle
    var history: [TranscriptItem] = HistoryStore.load()
    var selection: TranscriptItem.ID?
    var availableModels: [String] = []
    var lastCopiedID: TranscriptItem.ID?
    var downloadingModel: String?
    var downloadProgress: Double = 0
    var searchQuery: String = ""
    var downloadedSet: Set<String> = []        // какие модели на диске (реактивно)
    var modelSizes: [String: Int64] = [:]      // размер каждой скачанной модели

    // Настройки (зеркалятся в UserDefaults).
    var selectedModel: String { didSet { UserDefaults.standard.set(selectedModel, forKey: Keys.model) } }
    var language: String { didSet { UserDefaults.standard.set(language, forKey: Keys.language) } }
    var autoCopy: Bool { didSet { UserDefaults.standard.set(autoCopy, forKey: Keys.autoCopy) } }
    var showTimestamps: Bool { didSet { UserDefaults.standard.set(showTimestamps, forKey: Keys.timestamps) } }
    var translateToEnglish: Bool { didSet { UserDefaults.standard.set(translateToEnglish, forKey: Keys.translate) } }

    private let engine = TranscriptionEngine()

    private enum Keys {
        static let model = "model"
        static let language = "language"
        static let autoCopy = "autoCopy"
        static let timestamps = "timestamps"
        static let translate = "translateToEnglish"
    }

    init() {
        let d = UserDefaults.standard
        selectedModel = d.string(forKey: Keys.model) ?? "openai_whisper-large-v3-v20240930"
        language = d.string(forKey: Keys.language) ?? ""
        autoCopy = (d.object(forKey: Keys.autoCopy) as? Bool) ?? true
        showTimestamps = d.bool(forKey: Keys.timestamps)
        translateToEnglish = d.bool(forKey: Keys.translate)
        availableModels = [
            "openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small",
            "openai_whisper-large-v3", "openai_whisper-large-v3-v20240930",
            "openai_whisper-large-v3-v20240930_turbo_632MB",
        ]
        if !availableModels.contains(selectedModel) { availableModels.insert(selectedModel, at: 0) }
        refreshDownloaded()
    }

    var isBusy: Bool {
        switch phase { case .idle, .failed: return false; default: return true }
    }

    /// Элемент для правой панели — из ВИДИМОГО (отфильтрованного) списка, чтобы панель и
    /// сайдбар не расходились при активном поиске.
    var selectedItem: TranscriptItem? {
        if let id = selection, let found = filteredHistory.first(where: { $0.id == id }) { return found }
        return filteredHistory.first
    }

    var filteredHistory: [TranscriptItem] { filterHistory(history, query: searchQuery) }

    // MARK: Модели — статус/размер на диске

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
            phase = .failed("Не удалось скачать модель: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
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
            phase = .failed("Не удалось удалить модель: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
        }
    }

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
        add("Tiny", "очень быстро · черновик", "~75 МБ", ["openai_whisper-tiny"])
        add("Base", "быстро · базовое качество", "~150 МБ", ["openai_whisper-base"])
        add("Small", "баланс скорость / точность", "~500 МБ", ["openai_whisper-small"])
        add("Large v3 turbo", "быстро, почти максимум · топ для ru/uk", "~630 МБ",
            ["openai_whisper-large-v3-v20240930_626MB",
             "openai_whisper-large-v3-v20240930",
             "openai_whisper-large-v3-v20240930_turbo_632MB",
             "openai_whisper-large-v3-v20240930_turbo"], rec: true)
        add("Large v3", "максимум точности · медленнее", "~1 ГБ",
            ["openai_whisper-large-v3", "openai_whisper-large-v3_947MB"])
        if !tiers.contains(where: { $0.name == selectedModel }) {
            tiers.append(ModelTier(title: friendlyModel(selectedModel), hint: "текущая выбранная",
                                   estimate: "", name: selectedModel, recommended: false))
        }
        return tiers
    }

    // MARK: Транскрибация

    func handleDrop(urls: [URL]) {
        guard !isBusy, downloadingModel == nil else { return }
        phase = .preparing("…")   // синхронно занимаем фазу — закрываем гонку двойного дропа
        Task { await transcribe(urls: urls) }
    }

    func transcribe(urls: [URL]) async {
        var files: [URL] = []
        for url in urls {
            if url.hasDirectoryPath { files.append(contentsOf: Self.audioFiles(in: url)) }
            else { files.append(url) }
        }
        guard !files.isEmpty else {
            phase = .failed("Не нашёл аудиофайлов")
            return
        }
        var failures: [String] = []
        for url in files {
            do {
                phase = .preparing(url.lastPathComponent)
                let wav = try await Task.detached(priority: .userInitiated) {
                    try AudioConverter.toWav16k(url)
                }.value
                defer { try? FileManager.default.removeItem(at: wav) }

                phase = .loadingModel
                try await engine.ensureLoaded(model: selectedModel, progress: progressHandler())

                phase = .transcribing(url.lastPathComponent)
                let lang = language.isEmpty ? nil : language
                let r = try await engine.transcribe(wavPath: wav.path, language: lang,
                                                    model: selectedModel, translate: translateToEnglish)

                let item = TranscriptItem(
                    sourceName: url.lastPathComponent,
                    language: r.language,
                    durationSec: r.duration,
                    model: selectedModel,
                    text: r.text.isEmpty ? "(тишина — ничего не распознано)" : r.text,
                    segments: r.segments
                )
                history.insert(item, at: 0)
                selection = item.id
                HistoryStore.save(history)
                if autoCopy, !r.text.isEmpty { copy(item.text) }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                failures.append("\(url.lastPathComponent) (\(msg))")
            }
        }
        refreshDownloaded()
        phase = failures.isEmpty ? .idle : .failed("Не удалось: \(failures.joined(separator: "; "))")
    }

    private func progressHandler() -> @Sendable (ModelLoad) -> Void {
        { [weak self] load in
            Task { @MainActor in
                guard let self else { return }
                switch load {
                case .downloading(let p): self.phase = .downloadingModel(p)
                case .loading: self.phase = .loadingModel
                }
            }
        }
    }

    // MARK: История

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyItem(_ item: TranscriptItem) {
        copy(item.display(timestamps: showTimestamps))
        lastCopiedID = item.id
        // «Скопировано» — кратковременная подсветка, сбрасываем.
        let id = item.id
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if lastCopiedID == id { lastCopiedID = nil }
        }
    }

    /// Сохранить отредактированный текст карточки в историю.
    /// Резолвит запись по `id` (а не по копии), штампует `edited`/`editedAt`, пишет на диск.
    /// Возвращает true, если текст реально изменился (для UI-фидбэка); no-op правка → false.
    @discardableResult
    func saveEdit(_ rawText: String, for id: TranscriptItem.ID) -> Bool {
        guard let idx = history.firstIndex(where: { $0.id == id }) else { return false }
        let (newText, changed) = normalizedEdit(rawText, from: history[idx].text)
        guard changed else { return false }   // ничего по сути не поменялось → не пишем и не штампуем
        history[idx].text = newText
        history[idx].edited = true
        history[idx].editedAt = Date()
        HistoryStore.save(history)
        selection = id                        // держим выделение на отредактированной записи
        return true
    }

    func delete(_ item: TranscriptItem) {
        history.removeAll { $0.id == item.id }
        if selection == item.id { selection = nil }
        HistoryStore.save(history)
    }

    func clearHistory() {
        history.removeAll()
        selection = nil
        HistoryStore.save(history)
    }

    /// Экспорт всей истории в markdown-файл (диалог сохранения).
    func exportHistory() {
        guard !history.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "parla-history.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(exportText(history).utf8).write(to: url)
        } catch {
            phase = .failed("Не удалось сохранить файл: \(error.localizedDescription)")
        }
    }

    // MARK: Чистые статики

    nonisolated static func bestDefault(from models: [String]) -> String {
        if let exact = models.first(where: { $0 == "openai_whisper-large-v3-v20240930" }) { return exact }
        if let turbo = models.first(where: { $0.contains("large-v3-v20240930") }) { return turbo }
        if let v3 = models.first(where: { $0.contains("large-v3") }) { return v3 }
        if let base = models.first(where: { $0.contains("base") && !$0.contains(".en") }) { return base }
        return models.first ?? "openai_whisper-base"
    }

    nonisolated static let audioExts: Set<String> = [
        "ogg", "oga", "opus", "m4a", "mp3", "wav", "aac", "flac",
        "mp4", "mov", "m4v", "webm", "3gp", "amr", "wma", "aiff", "aif", "caf",
    ]
    nonisolated static func audioFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return en.compactMap { $0 as? URL }
            .filter { audioExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
