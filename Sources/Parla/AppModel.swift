import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WhisperKit

/// Единственный `@Observable` view-model, к которому привязан SwiftUI. Здесь живут СОСТОЯНИЕ и
/// НАСТРОЙКИ; поведение разнесено по доменным расширениям:
/// `AppModel+Models` · `+Transcription` · `+FolderWatch` · `+QuickActions` · `+History` · `+AudioCache`.
/// Stored-свойства нельзя держать в extension, поэтому кросс-доменное состояние объявлено тут и
/// шарится с расширениями (часть из-за этого `internal`, а не `private`).
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

    // Слежение за папкой (фича 04) — тот же didSet-паттерн зеркалирования в UserDefaults.
    var watchEnabled: Bool      { didSet { UserDefaults.standard.set(watchEnabled, forKey: Keys.watchEnabled); applyWatchToggle() } }
    var watchRecursive: Bool    { didSet { UserDefaults.standard.set(watchRecursive, forKey: Keys.watchRecursive); if watchEnabled { restartWatching() } } }
    var watchWriteSidecar: Bool { didSet { UserDefaults.standard.set(watchWriteSidecar, forKey: Keys.watchSidecar) } }
    var globalHotkeyEnabled: Bool { didSet { UserDefaults.standard.set(globalHotkeyEnabled, forKey: Keys.hotkey) } }

    /// Язык интерфейса — отдельно от языка распознавания речи (`language`). `.system` следует за ОС.
    var uiLanguage: UILanguage {
        didSet {
            UserDefaults.standard.set(uiLanguage.rawValue, forKey: Keys.uiLanguage)
            Localized.setLanguage(uiLanguage.code)
        }
    }

    /// Локаль для SwiftUI `environment(\.locale)` (форматирование + системные контролы).
    var resolvedLocale: Locale { uiLanguage.locale }

    var watchedFolderURL: URL?          // резолвится из bookmark — для отображения пути
    var watchQueueCount: Int = 0        // сколько файлов ждут в очереди (для статус-чипа)

    // Состояние, общее с расширениями (нельзя в extension → internal, не private).
    var quickModeRun = false                          // запуск из хоткея/меню-бара → тост по завершении (+Transcription/+QuickActions)
    var watcher: FolderWatcher?                        // +FolderWatch
    var watchQueue: [URL] = []                         // ждут транскрибации (single-flight)
    var lastSeen: [String: WatchedFileStat] = [:]      // снимок прошлого прохода (стабильность)
    var processedKeys: [String] = []                   // FIFO-порядок обработанных dedupKey
    var processedSet: Set<String> = []                 // = Set(processedKeys), для O(1) проверки

    let engine = TranscriptionEngine()                 // +Models (delete) / +Transcription (load+run)

    enum Keys {
        static let model = "model"
        static let language = "language"
        static let autoCopy = "autoCopy"
        static let timestamps = "timestamps"
        static let translate = "translateToEnglish"
        static let watchEnabled = "watchEnabled"
        static let watchRecursive = "watchRecursive"
        static let watchSidecar = "watchWriteSidecar"
        static let watchBookmark = "watchBookmark"
        static let hotkey = "globalHotkeyEnabled"
        static let lastBookmark = "lastSourceBookmark"
        static let uiLanguage = "uiLanguage"
    }

    init() {
        let d = UserDefaults.standard
        selectedModel = d.string(forKey: Keys.model) ?? "openai_whisper-large-v3-v20240930"
        language = d.string(forKey: Keys.language) ?? ""
        autoCopy = (d.object(forKey: Keys.autoCopy) as? Bool) ?? true
        showTimestamps = d.bool(forKey: Keys.timestamps)
        translateToEnglish = d.bool(forKey: Keys.translate)
        watchEnabled = d.bool(forKey: Keys.watchEnabled)
        watchRecursive = (d.object(forKey: Keys.watchRecursive) as? Bool) ?? true   // подпапки по умолчанию вкл.
        watchWriteSidecar = d.bool(forKey: Keys.watchSidecar)
        globalHotkeyEnabled = d.bool(forKey: Keys.hotkey)   // opt-in, по умолчанию выкл.
        uiLanguage = UILanguage(rawValue: d.string(forKey: Keys.uiLanguage) ?? "") ?? .system
        Localized.setLanguage(uiLanguage.code)              // применить выбранный язык интерфейса до первой строки
        processedKeys = ProcessedStore.load()
        processedSet = Set(processedKeys)
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

    // «Что считается аудио» — кросс-доменная утилита (используется транскрибацией, слежением, буфером).
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
