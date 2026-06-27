import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WhisperKit

/// How the dictation hotkey behaves: press once to start/stop (default) vs hold-to-talk (press-and-hold).
enum DictationMode: String, CaseIterable, Identifiable {
    case toggle, hold
    var id: String { rawValue }
    var label: String { self == .hold ? L("settings.dictation.mode.hold") : L("settings.dictation.mode.toggle") }
}


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
    var lastAttemptedURLs: [URL] = []          // last input passed to transcribe — for «Try again» on failure
    var downloadingModel: String?
    var downloadProgress: Double = 0
    var searchQuery: String = ""
    var relatedIDs: [UUID] = []                         // "Related notes" to the OPEN item (doc↔doc semantic, P1) — recomputed on selection
    @ObservationIgnored var embeddingIndex: [UUID: Embedding] = [:]   // in-memory mirror of embeddings.json (doc↔doc related reads it; effect flows through observable relatedIDs)
    var lemmaIndex: [UUID: Set<String>] = [:]                         // per-item lemma set for morphology search; OBSERVED — filteredHistory depends on it, so it must re-evaluate when the index builds
    var downloadedSet: Set<String> = []        // which models are on disk (reactive)
    var modelSizes: [String: Int64] = [:]      // size of each downloaded model

    // Settings (mirrored into UserDefaults).
    var selectedModel: String { didSet { UserDefaults.standard.set(selectedModel, forKey: Keys.model) } }
    var language: String { didSet { UserDefaults.standard.set(language, forKey: Keys.language) } }
    var autoCopy: Bool { didSet { UserDefaults.standard.set(autoCopy, forKey: Keys.autoCopy) } }
    var showTimestamps: Bool { didSet { UserDefaults.standard.set(showTimestamps, forKey: Keys.timestamps) } }
    var translateToEnglish: Bool { didSet { UserDefaults.standard.set(translateToEnglish, forKey: Keys.translate) } }
    var soundOnComplete: Bool { didSet { UserDefaults.standard.set(soundOnComplete, forKey: Keys.sound) } }

    // Folder watching (feature 04) — same didSet pattern for mirroring into UserDefaults.
    var watchEnabled: Bool      { didSet { UserDefaults.standard.set(watchEnabled, forKey: Keys.watchEnabled); applyWatchToggle() } }
    var watchRecursive: Bool    { didSet { UserDefaults.standard.set(watchRecursive, forKey: Keys.watchRecursive); if watchEnabled { restartWatching() } } }
    var watchWriteSidecar: Bool { didSet { UserDefaults.standard.set(watchWriteSidecar, forKey: Keys.watchSidecar) } }
    var globalHotkeyEnabled: Bool { didSet { UserDefaults.standard.set(globalHotkeyEnabled, forKey: Keys.hotkey) } }

    // Dictation (feature MIC_DICTATION) — opt-in hotkey + whether to keep the recorded audio.
    var dictationHotkeyEnabled: Bool { didSet { UserDefaults.standard.set(dictationHotkeyEnabled, forKey: Keys.dictationHotkey) } }
    var keepDictationAudio: Bool { didSet { UserDefaults.standard.set(keepDictationAudio, forKey: Keys.keepDictationAudio) } }
    /// Paste the dictation result into the frontmost app (the ONLY Accessibility feature — off by default).
    var dictationPasteIntoFrontmost: Bool { didSet { UserDefaults.standard.set(dictationPasteIntoFrontmost, forKey: Keys.dictationPaste) } }
    /// Hotkey behavior: press-to-toggle (default) vs hold-to-talk.
    var dictationMode: DictationMode { didSet { UserDefaults.standard.set(dictationMode.rawValue, forKey: Keys.dictationMode) } }
    // AI insights, shown as editable fields in the card (P1). Each is independently toggleable; ON by default.
    var showTitles: Bool { didSet { UserDefaults.standard.set(showTitles, forKey: Keys.showTitles) } }
    var showKeywords: Bool { didSet { UserDefaults.standard.set(showKeywords, forKey: Keys.showKeywords) } }
    var showSummaries: Bool { didSet { UserDefaults.standard.set(showSummaries, forKey: Keys.showSummaries) } }
    /// Auto-stop a dictation after a short run of silence (opt-in, off by default).
    var dictationVADEnabled: Bool { didSet { UserDefaults.standard.set(dictationVADEnabled, forKey: Keys.dictationVAD) } }
    /// Live segment-level streaming preview while dictating (opt-in, off by default). PREVIEW ONLY — the
    /// saved transcript still comes from the full offline decode in `finishDictation`.
    var dictationLiveStreaming: Bool { didSet { UserDefaults.standard.set(dictationLiveStreaming, forKey: Keys.dictationLiveStreaming) } }

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
    var recorder: MicRecorder?                         // +Dictation (live mic capture)
    var recordingStartedAt: Date?                      // +Dictation: non-nil while recording (drives isBusy + the chip timer)
    var requestingMic = false                          // +Dictation: holds the lane during the mic-permission check,
                                                       // BEFORE any recording UI shows (recordingStartedAt stays nil)
    var streamingTask: Task<Void, Never>?              // +DictationStream: the live decode loop (single-flight)
    var dictationConfirmedText = ""                    // +DictationStream: stable streamed prefix (render solid)
    var dictationHypothesisText = ""                   // +DictationStream: live streamed tail (render dimmed)
    var refiningDictations: Set<UUID> = []             // +Dictation: items showing the streamed text while a full
                                                       // decode refines them (transient — never persisted, so a
                                                       // quit mid-refine just leaves the good streamed text)
    var watchQueue: [URL] = []                         // waiting for transcription (single-flight)
    var lastSeen: [String: WatchedFileStat] = [:]      // snapshot of the previous pass (stability)
    var processedKeys: [String] = []                   // FIFO order of processed dedupKeys
    var processedSet: Set<String> = []                 // = Set(processedKeys), for O(1) lookups
    var semanticRefreshInFlight = false                // single-flight guard for the semantic backfill (P1)
    var semanticRefreshPending = false                 // a change arrived mid-refresh → run once more after

    let engine: any TranscribingEngine                 // +Models (delete) / +Transcription (load+run) — injectable (test seam)
    let ai: any LocalLLMService                         // Local-AI Layer seam (P0) — injectable; unused until P2 wires enrich
    let embedder: any TextEmbedder                      // semantic-embedding seam (P1) — injectable; NLContextualEmbedding default

    /// WAV conversion (test seam): real ffmpeg by default; tests inject a stub to skip ffmpeg.
    var wavConverter: @Sendable (URL) throws -> URL = { try AudioConverter.toWav16k($0) }

    /// Completion-notification dispatch (test seam): real UNUserNotificationCenter in production;
    /// tests inject a no-op so they don't touch the notification center (no bundle proxy under XCTest).
    var postNotification: (_ succeeded: Int, _ failed: Int) async -> Void = {
        await BatchNotifier.post(succeeded: $0, failed: $1)
    }

    /// Paste-into-frontmost (test seam): real CGEvent ⌘V in production; tests inject a recorder.
    /// Returns whether a synthetic paste was actually performed (false → not Accessibility-trusted).
    var attemptPaste: @MainActor () -> Bool = { PasteService.pasteIntoFrontmost() }

    enum Keys {
        static let model = "model"
        static let language = "language"
        static let autoCopy = "autoCopy"
        static let timestamps = "timestamps"
        static let sound = "soundOnComplete"
        static let translate = "translateToEnglish"
        static let watchEnabled = "watchEnabled"
        static let watchRecursive = "watchRecursive"
        static let watchSidecar = "watchWriteSidecar"
        static let watchBookmark = "watchBookmark"
        static let hotkey = "globalHotkeyEnabled"
        static let dictationHotkey = "dictationHotkeyEnabled"
        static let keepDictationAudio = "keepDictationAudio"
        static let dictationPaste = "dictationPasteIntoFrontmost"
        static let dictationPasteAXPrompted = "dictationPasteAXPrompted"   // one-time AX prompt guard
        static let dictationMode = "dictationMode"
        static let showTitles = "aiShowTitles"
        static let showKeywords = "aiShowKeywords"
        static let showSummaries = "aiShowSummaries"
        static let dictationVAD = "dictationVADEnabled"
        static let dictationLiveStreaming = "dictationLiveStreaming"
        static let lastBookmark = "lastSourceBookmark"
        static let uiLanguage = "uiLanguage"
    }

    /// Default embedder: the real on-device `NLEmbedder` in production, a `NoopEmbedder` under unit tests — so a
    /// test that doesn't inject a fake never loads the `NLContextualEmbedding` model or downloads its assets, and
    /// the kicked refresh stays instant (same `XCTestCase` headless gate as `PasteService`/`CompletionSound`).
    static func defaultEmbedder() -> any TextEmbedder {
        NSClassFromString("XCTestCase") != nil ? NoopEmbedder() : NLEmbedder()
    }

    /// Default AI backend: the real `DefaultAIService` in production, a `NoopAIService` under unit tests — so a
    /// test that doesn't inject a fake never calls the real on-device FoundationModels session (slow + non-deterministic).
    static func defaultAI() -> any LocalLLMService {
        NSClassFromString("XCTestCase") != nil ? NoopAIService() : DefaultAIService()
    }

    init(engine: any TranscribingEngine = TranscriptionEngine(),
         ai: any LocalLLMService = AppModel.defaultAI(),
         embedder: any TextEmbedder = AppModel.defaultEmbedder()) {
        self.engine = engine
        self.ai = ai
        self.embedder = embedder
        let d = UserDefaults.standard
        selectedModel = d.string(forKey: Keys.model) ?? "openai_whisper-large-v3-v20240930_626MB"   // quantized turbo: best quality/size on RU (see bestDefault)
        language = d.string(forKey: Keys.language) ?? ""
        autoCopy = (d.object(forKey: Keys.autoCopy) as? Bool) ?? true
        showTimestamps = (d.object(forKey: Keys.timestamps) as? Bool) ?? true   // default ON: reveal the click-to-seek SegmentList
        translateToEnglish = d.bool(forKey: Keys.translate)
        soundOnComplete = (d.object(forKey: Keys.sound) as? Bool) ?? true
        watchEnabled = d.bool(forKey: Keys.watchEnabled)
        watchRecursive = (d.object(forKey: Keys.watchRecursive) as? Bool) ?? true   // subfolders on by default
        watchWriteSidecar = d.bool(forKey: Keys.watchSidecar)
        globalHotkeyEnabled = d.bool(forKey: Keys.hotkey)   // opt-in, off by default
        dictationHotkeyEnabled = d.bool(forKey: Keys.dictationHotkey)   // opt-in, off by default
        keepDictationAudio = d.bool(forKey: Keys.keepDictationAudio)    // off — dictation audio is throwaway
        dictationPasteIntoFrontmost = d.bool(forKey: Keys.dictationPaste)   // off — the only Accessibility feature
        dictationMode = DictationMode(rawValue: d.string(forKey: Keys.dictationMode) ?? "") ?? .toggle
        showTitles = (d.object(forKey: Keys.showTitles) as? Bool) ?? true        // AI insight fields ON by default…
        showKeywords = (d.object(forKey: Keys.showKeywords) as? Bool) ?? true    // …each independently disableable
        showSummaries = (d.object(forKey: Keys.showSummaries) as? Bool) ?? true
        dictationVADEnabled = d.bool(forKey: Keys.dictationVAD)   // opt-in, off by default
        dictationLiveStreaming = (d.object(forKey: Keys.dictationLiveStreaming) as? Bool) ?? true   // ON by default (safe + measured; preview-only)
        uiLanguage = UILanguage(rawValue: d.string(forKey: Keys.uiLanguage) ?? "") ?? .en   // English by default (international release)
        Localized.setLanguage(uiLanguage.code)              // apply the chosen UI language before the first string
        processedKeys = ProcessedStore.load()
        processedSet = Set(processedKeys)
        // Seed so the turbo tier + onboarding resolve to _626MB BEFORE the async refreshModels() returns
        // (the onboarding pick reads this list at first launch; refreshModels lands later).
        availableModels = [
            "openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small",
            "openai_whisper-large-v3",
            "openai_whisper-large-v3-v20240930_626MB", "openai_whisper-large-v3-v20240930",
            "openai_whisper-large-v3-v20240930_turbo_632MB",
        ]
        if !availableModels.contains(selectedModel) { availableModels.insert(selectedModel, at: 0) }
        refreshDownloaded()
    }

    var isBusy: Bool {
        if recordingStartedAt != nil { return true }   // recording a dictation blocks other jobs (single-flight)
        if requestingMic { return true }                // mic-permission check in flight — hold the lane (no gap)
        if !refiningDictations.isEmpty { return true }  // a hybrid refine is decoding — hold the lane (no concurrent
                                                        // job, and the edit pencil stays hidden so it can't clobber)
        switch phase { case .idle, .failed: return false; default: return true }
    }

    /// Quitting now would discard work in flight (a transcription job — only saved at the end —
    /// or an in-progress model download). The AppDelegate gates termination on this.
    /// A hybrid refine does NOT count: its streamed transcript is already saved to disk; only the optional
    /// accuracy upgrade would be skipped, which is fine to abandon — so it must not trigger the "work will be
    /// lost" prompt (it still holds `isBusy` to block concurrent jobs).
    var shouldConfirmQuit: Bool {
        if recordingStartedAt != nil || downloadingModel != nil { return true }
        return isBusy && refiningDictations.isEmpty
    }

    /// Item for the right pane — taken from the VISIBLE (filtered) list, so the pane and
    /// the sidebar don't diverge while a search is active.
    var selectedItem: TranscriptItem? {
        if let id = selection, let found = filteredHistory.first(where: { $0.id == id }) { return found }
        return filteredHistory.first
    }

    var filteredHistory: [TranscriptItem] { filterHistory(history, query: searchQuery, lemmaIndex: lemmaIndex) }

    /// Most recent transcript's text, or "" — the read value behind GetLastTranscriptIntent (Shortcuts).
    var lastTranscriptText: String { history.first?.text ?? "" }

    // «What counts as audio» — a cross-domain utility (used by transcription, watching, and the buffer).
    nonisolated static let audioExts: Set<String> = [
        "ogg", "oga", "opus", "m4a", "mp3", "wav", "aac", "flac",
        "mp4", "mov", "m4v", "webm", "3gp", "amr", "wma", "aiff", "aif", "caf",
    ]

    /// Formats AVFoundation opens directly — WhisperKit loads audio via `AVAudioFile(forReading:)` and
    /// resamples to 16 kHz itself, so these can go straight to the engine with NO ffmpeg re-encode.
    /// Conservative v1 = the EXACT mirror of the prod-proven `AudioStore.directlyPlayable` (pure-audio
    /// containers). Video containers (mp4/mov/m4v) deliberately stay on the ffmpeg path — `AVAudioFile`
    /// is unreliable for them. Must remain a strict subset of `audioExts` (pinned by test): a format
    /// wrongly listed here would hard-fail instead of routing through ffmpeg.
    nonisolated static let avDecodable: Set<String> = ["m4a", "mp3", "wav", "aac", "caf", "aiff", "aif"]
    nonisolated static func audioFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return en.compactMap { $0 as? URL }
            .filter { audioExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
