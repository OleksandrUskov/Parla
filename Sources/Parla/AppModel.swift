import SwiftUI
import AppKit
import WhisperKit

@MainActor
@Observable
final class AppModel {
    var phase: EnginePhase = .idle
    var history: [TranscriptItem] = HistoryStore.load()
    var selection: TranscriptItem.ID?
    var availableModels: [String] = []
    var lastCopiedID: TranscriptItem.ID?
    var downloadingModel: String?       // какая модель качается прямо сейчас (в менеджере)
    var downloadProgress: Double = 0

    // Настройки (зеркалятся в UserDefaults).
    var selectedModel: String { didSet { UserDefaults.standard.set(selectedModel, forKey: Keys.model) } }
    var language: String { didSet { UserDefaults.standard.set(language, forKey: Keys.language) } }
    var autoCopy: Bool { didSet { UserDefaults.standard.set(autoCopy, forKey: Keys.autoCopy) } }
    var showTimestamps: Bool { didSet { UserDefaults.standard.set(showTimestamps, forKey: Keys.timestamps) } }

    private let engine = TranscriptionEngine()

    private enum Keys {
        static let model = "model"
        static let language = "language"
        static let autoCopy = "autoCopy"
        static let timestamps = "timestamps"
    }

    init() {
        let d = UserDefaults.standard
        selectedModel = d.string(forKey: Keys.model) ?? "openai_whisper-large-v3-v20240930"
        language = d.string(forKey: Keys.language) ?? ""
        autoCopy = (d.object(forKey: Keys.autoCopy) as? Bool) ?? true
        showTimestamps = d.bool(forKey: Keys.timestamps)
        availableModels = [
            "openai_whisper-tiny",
            "openai_whisper-base",
            "openai_whisper-small",
            "openai_whisper-large-v3",
            "openai_whisper-large-v3-v20240930",
            "openai_whisper-large-v3-v20240930_turbo_632MB",
        ]
        if !availableModels.contains(selectedModel) { availableModels.insert(selectedModel, at: 0) }
    }

    var isBusy: Bool {
        switch phase {
        case .idle, .failed: return false
        default: return true
        }
    }

    var selectedItem: TranscriptItem? {
        if let id = selection, let found = history.first(where: { $0.id == id }) { return found }
        return history.first
    }

    /// Модель уже скачана на диск (для галочек в UI).
    func isDownloaded(_ model: String) -> Bool { TranscriptionEngine.isDownloaded(model) }

    func refreshModels() async {
        let support = await WhisperKit.recommendedRemoteModels()
        let models = support.supported.sorted()
        guard !models.isEmpty else { return }
        availableModels = models
        if !models.contains(selectedModel) {
            selectedModel = Self.bestDefault(from: models)
        }
    }

    func handleDrop(urls: [URL]) {
        guard !isBusy else { return }
        Task { await transcribe(urls: urls) }
    }

    func delete(_ item: TranscriptItem) {
        history.removeAll { $0.id == item.id }
        if selection == item.id { selection = nil }
        HistoryStore.save(history)
    }

    /// Скачать конкретную модель заранее (без транскрибации, не трогая загруженную).
    /// Идёт напрямую через WhisperKit.download — НЕ блокирует движок, можно качать в фоне.
    func downloadModel(_ name: String) async {
        guard downloadingModel == nil, !TranscriptionEngine.isDownloaded(name) else { return }
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
    }

    /// Модели в понятном порядке (turbo → … → tiny) для менеджера.
    var curatedModels: [String] {
        func rank(_ m: String) -> Int {
            if m.contains("large-v3-v20240930") { return 0 }   // turbo
            if m.contains("large-v3") { return 1 }
            if m.contains("large-v2") { return 2 }
            if m.contains("medium") { return 3 }
            if m.contains("small") { return 4 }
            if m.contains("base") { return 5 }
            if m.contains("tiny") { return 6 }
            return 7
        }
        return availableModels.sorted { (rank($0), $0) < (rank($1), $1) }
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

    func transcribe(urls: [URL]) async {
        // Папку разворачиваем в её аудиофайлы; одиночные файлы отдаём ffmpeg как есть.
        var files: [URL] = []
        for url in urls {
            if url.hasDirectoryPath { files.append(contentsOf: Self.audioFiles(in: url)) }
            else { files.append(url) }
        }
        guard !files.isEmpty else {
            phase = .failed("Не нашёл аудиофайлов")
            return
        }
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
                let r = try await engine.transcribe(wavPath: wav.path, language: lang, model: selectedModel)

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
                phase = .idle
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                phase = .failed(msg)
            }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyItem(_ item: TranscriptItem) {
        copy(item.display(timestamps: showTimestamps))
        lastCopiedID = item.id
    }

    func clearHistory() {
        history.removeAll()
        selection = nil
        HistoryStore.save(history)
    }

    static func bestDefault(from models: [String]) -> String {
        if let exact = models.first(where: { $0 == "openai_whisper-large-v3-v20240930" }) { return exact }
        if let turbo = models.first(where: { $0.contains("large-v3-v20240930") }) { return turbo }
        if let v3 = models.first(where: { $0.contains("large-v3") }) { return v3 }
        if let base = models.first(where: { $0.contains("base") && !$0.contains(".en") }) { return base }
        return models.first ?? "openai_whisper-base"
    }

    static let audioExts: Set<String> = [
        "ogg", "oga", "opus", "m4a", "mp3", "wav", "aac", "flac",
        "mp4", "mov", "m4v", "webm", "3gp", "amr", "wma", "aiff", "aif", "caf",
    ]
    static func audioFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return en.compactMap { $0 as? URL }
            .filter { audioExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
