import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WhisperKit

/// The single `@Observable` view-model SwiftUI binds to. STATE and SETTINGS live here;
/// behavior is split across domain extensions:
/// `AppModel+Models` · `+Transcription` · `+FolderWatch` · `+QuickActions` · `+History` · `+AudioCache`.
/// Stored properties can't live in an extension, so cross-domain state is declared here and
/// shared with the extensions (which is why some of it is `internal` rather than `private`).
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
    var downloadedSet: Set<String> = []        // which models are on disk (reactive)
    var modelSizes: [String: Int64] = [:]      // size of each downloaded model

    // Settings (mirrored into UserDefaults).
    var selectedModel: String { didSet { UserDefaults.standard.set(selectedModel, forKey: Keys.model) } }
    var language: String { didSet { UserDefaults.standard.set(language, forKey: Keys.language) } }
    var autoCopy: Bool { didSet { UserDefaults.standard.set(autoCopy, forKey: Keys.autoCopy) } }
    var showTimestamps: Bool { didSet { UserDefaults.standard.set(showTimestamps, forKey: Keys.timestamps) } }
    var translateToEnglish: Bool { didSet { UserDefaults.standard.set(translateToEnglish, forKey: Keys.translate) } }

    // Folder watching (feature 04) — same didSet pattern for mirroring into UserDefaults.
    var watchEnabled: Bool      { didSet { UserDefaults.standard.set(watchEnabled, forKey: Keys.watchEnabled); applyWatchToggle() } }
    var watchRecursive: Bool    { didSet { UserDefaults.standard.set(watchRecursive, forKey: Keys.watchRecursive); if watchEnabled { restartWatching() } } }
    var watchWriteSidecar: Bool { didSet { UserDefaults.standard.set(watchWriteSidecar, forKey: Keys.watchSidecar) } }
    var globalHotkeyEnabled: Bool { didSet { UserDefaults.standard.set(globalHotkeyEnabled, forKey: Keys.hotkey) } }

    /// UI language — separate from the speech-recognition language (`language`). `.system` follows the OS.
    var uiLanguage: UILanguage {
        didSet {
            UserDefaults.standard.set(uiLanguage.rawValue, forKey: Keys.uiLanguage)
            Localized.setLanguage(uiLanguage.code)
        }
    }

    /// Locale for SwiftUI `environment(\.locale)` (formatting + system controls).
    var resolvedLocale: Locale { uiLanguage.locale }

    var watchedFolderURL: URL?          // resolved from a bookmark — for displaying the path
    var watchQueueCount: Int = 0        // how many files are waiting in the queue (for the status chip)

    // State shared with the extensions (can't be in an extension → internal, not private).
    var quickModeRun = false                          // launched from hotkey/menu bar → toast on completion (+Transcription/+QuickActions)
    var watcher: FolderWatcher?                        // +FolderWatch
    var watchQueue: [URL] = []                         // waiting for transcription (single-flight)
    var lastSeen: [String: WatchedFileStat] = [:]      // snapshot of the previous pass (stability)
    var processedKeys: [String] = []                   // FIFO order of processed dedupKeys
    var processedSet: Set<String> = []                 // = Set(processedKeys), for O(1) lookups

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
        watchRecursive = (d.object(forKey: Keys.watchRecursive) as? Bool) ?? true   // subfolders on by default
        watchWriteSidecar = d.bool(forKey: Keys.watchSidecar)
        globalHotkeyEnabled = d.bool(forKey: Keys.hotkey)   // opt-in, off by default
        uiLanguage = UILanguage(rawValue: d.string(forKey: Keys.uiLanguage) ?? "") ?? .system
        Localized.setLanguage(uiLanguage.code)              // apply the chosen UI language before the first string
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

    /// Item for the right pane — taken from the VISIBLE (filtered) list, so the pane and
    /// the sidebar don't diverge while a search is active.
    var selectedItem: TranscriptItem? {
        if let id = selection, let found = filteredHistory.first(where: { $0.id == id }) { return found }
        return filteredHistory.first
    }

    var filteredHistory: [TranscriptItem] { filterHistory(history, query: searchQuery) }

    // «What counts as audio» — a cross-domain utility (used by transcription, watching, and the buffer).
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
