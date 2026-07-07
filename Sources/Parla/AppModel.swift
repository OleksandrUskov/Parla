import SwiftUI
import ParlaCore
import Foundation
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
    var semanticHitIDs: [UUID] = []                     // download-tier query→note matches (P3.5) — blended into filteredHistory below the lexical hits
    @ObservationIgnored var searchDebounce: Task<Void, Never>?   // debounces the semantic search on each keystroke
    @ObservationIgnored var embeddingIndex: [UUID: Embedding] = [:]   // in-memory mirror of embeddings.json (doc↔doc related reads it; effect flows through observable relatedIDs)
    @ObservationIgnored var enrichFailedIDs: Set<UUID> = []           // items whose generative enrich hard-failed this session — don't re-submit to the slow model every refresh (cleared on edit / next launch)
    var lemmaIndex: [UUID: Set<String>] = [:]                         // per-item lemma set for morphology search; OBSERVED — filteredHistory depends on it, so it must re-evaluate when the index builds
    var downloadedSet: Set<String> = []        // which models are on disk (reactive)
    var modelSizes: [String: Int64] = [:]      // size of each downloaded model
    // MLX RU/UK generative model (AI P3) — separate opt-in download, distinct from the WhisperKit variants.
    var mlxModelDownloaded: Bool = false       // RU/UK AI model present on disk (reactive)
    var mlxModelBytes: Int64 = 0               // its on-disk size (for the "disk used" line)
    var mlxDownloading: Bool = false           // single-flight + busy guard for the MLX download
    var mlxDownloadProgress: Double = 0
    var mlxDownloadError: String?              // last MLX download error — shown inline in the model row (cleared on retry/success)
    // Embedding model (AI P3.5) — opt-in download for query→note semantic search; distinct from the MLX LLM above.
    var embedModelDownloaded: Bool = false     // semantic-search model present on disk (reactive)
    var embedModelBytes: Int64 = 0             // its on-disk size (for the "disk used" line)
    var embedDownloading: Bool = false         // single-flight + busy guard for the embed-model download
    var embedDownloadProgress: Double = 0
    var embedDownloadError: String?            // last embed-model download error — shown inline in the row

    // Settings (mirrored into UserDefaults).
    var selectedModel: String { didSet { UserDefaults.standard.set(selectedModel, forKey: Keys.model) } }
    var language: String { didSet { UserDefaults.standard.set(language, forKey: Keys.language) } }
    var autoCopy: Bool { didSet { UserDefaults.standard.set(autoCopy, forKey: Keys.autoCopy) } }
    var showTimestamps: Bool { didSet { UserDefaults.standard.set(showTimestamps, forKey: Keys.timestamps) } }
    /// Pinned-player reading layout: fixes the chrome + audio player and gives the transcript its OWN scroll (vs the
    /// classic single-scroll page). ON by default; the toggle is the instant, code-free rollback if it doesn't land.
    var pinnedPlayerLayout: Bool { didSet { UserDefaults.standard.set(pinnedPlayerLayout, forKey: Keys.pinnedPlayer) } }
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
    var showActions: Bool { didSet { UserDefaults.standard.set(showActions, forKey: Keys.showActions) } }
    /// What an export includes — transcript / transcript+insights / insights-only. Chosen via the export menu,
    /// remembered across launches (the export is a one-shot artifact, so the choice rides with the user, not the note).
    var exportContent: ExportContent { didSet { UserDefaults.standard.set(exportContent.rawValue, forKey: Keys.exportContent) } }
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
    var regeneratingIDs: Set<UUID> = []                // +Semantic: items whose insights are being re-generated on
                                                       // demand (the "Regenerate" button) — drives a per-note spinner.
                                                       // OBSERVED (not @ObservationIgnored) so the button updates;
                                                       // transient, never persisted. Off the isBusy lane (best-effort).
    var summarizingChaptersIDs: Set<UUID> = []         // +Semantic: long notes whose per-chapter summaries are being
                                                       // generated on demand (the "Summarize chapters" button) — drives
                                                       // its spinner. OBSERVED; transient; off the isBusy lane (best-effort).
    var summarizingChapters: Set<ChapterRef> = []      // +Semantic: individual chapters being re-generated on demand
                                                       // (per-chapter "regenerate" button) — drives each chapter's spinner.
    var watchQueue: [URL] = []                         // waiting for transcription (single-flight)
    var transcriptionQueue: [TranscriptionJob] = []    // manual drops waiting for the lane — stack "5, then 5 more"; shares the isBusy lane with watchQueue
    var currentTranscriptionTask: Task<Void, Never>?   // the running MANUAL job — for Cancel (mirrors streamingTask); nil for watch/dictation runs
    var cancelling = false                             // a cancel was requested; the in-flight file/chunk finishes before it stops ("Stopping…")
    var lastSeen: [String: WatchedFileStat] = [:]      // snapshot of the previous pass (stability)
    var processedKeys: [String] = []                   // FIFO order of processed dedupKeys
    var processedSet: Set<String> = []                 // = Set(processedKeys), for O(1) lookups
    var semanticRefreshInFlight = false                // single-flight guard for the semantic backfill (P1)
    var semanticRefreshPending = false                 // a change arrived mid-refresh → run once more after

    let engine: any TranscribingEngine                 // +Models (delete) / +Transcription (load+run) — injectable (test seam)
    let ai: any LocalLLMService                         // Local-AI Layer seam (P0) — injectable; unused until P2 wires enrich
    let embedder: any TextEmbedder                      // semantic-embedding seam (P1) — injectable; NLContextualEmbedding default
    let tts: any TTSService                              // TTS seam (voice synthesis P1a) — injectable; SystemTTSService default (system voice)

    /// Audio decoding (platform + test seam): the inert Core default has no ffmpeg dependency; the macOS app
    /// wires `FFmpegAudioDecoder` via `AppModel.mac()` and iOS an in-process decoder (IOS_PORT.md §2). Tests
    /// inject a stub to script the decode.
    var decoder: any AudioDecoding = UnavailableAudioDecoder()

    /// Completion-notification dispatch (test seam): real UNUserNotificationCenter in production;
    /// tests inject a no-op so they don't touch the notification center (no bundle proxy under XCTest).
    var postNotification: (_ succeeded: Int, _ failed: Int) async -> Void = {
        await BatchNotifier.post(succeeded: $0, failed: $1)
    }

    /// Paste-into-frontmost (platform + test seam): macOS wires the real CGEvent ⌘V (`PasteService`) via
    /// `AppModel.mac()`; the inert Core/test default reports "not pasted". Returns whether a synthetic paste
    /// was actually performed (false → not Accessibility-trusted).
    var attemptPaste: @MainActor () -> Bool = { false }

    // MARK: Platform seams (iOS-port P0.1)
    // AppModel is Core-bound — it must stay AppKit-free so it ports to iOS. Each platform behavior below is an
    // injectable closure with an INERT Foundation-only default; the macOS app installs the real AppKit behavior
    // through `AppModel.mac()` (see AppModel+PlatformMac.swift). iOS will wire UIKit equivalents (IOS_PORT.md §1).

    /// Clipboard write: macOS wires `NSPasteboard`; inert default is a no-op (Core + tests stay AppKit-free).
    var copyToClipboard: @MainActor (String) -> Void = { _ in }

    /// Whether the app window is frontmost — gates the batch-completion notification. macOS wires
    /// `NSApplication.shared.isActive`; the inert default reports "not frontmost" (matches the headless/XCTest reality).
    var isAppActive: @MainActor () -> Bool = { false }

    /// Audio file URLs currently on the clipboard (drives «recognize from clipboard»): macOS wires
    /// `PasteboardReader`; inert default is empty.
    var clipboardAudioURLs: @MainActor () -> [URL] = { [] }

    /// Present a save dialog and return the chosen destination (or nil if cancelled): macOS wires `NSSavePanel`.
    /// The data production + write + error handling stay in Core — only the file-picker UI is platform-specific.
    var presentSavePanel: @MainActor (_ suggestedName: String, _ extensions: [String]) -> URL? = { _, _ in nil }

    /// Show a transient toast (macOS: `QuickToast` floating panel; iOS: its own overlay). `sticky` keeps it up
    /// until `hideToast`. Inert default is a no-op — the transcription result path stays platform-agnostic.
    var showToast: @MainActor (_ text: String, _ sticky: Bool) -> Void = { _, _ in }

    /// Dismiss a sticky toast (macOS: `QuickToast.hide`). Inert default is a no-op.
    var hideToast: @MainActor () -> Void = { }

    /// Play the batch-completion sound (macOS: `NSSound` Glass/Basso via `CompletionSound`). Inert default no-op.
    var playCompletionSound: @MainActor (_ success: Bool) -> Void = { _ in }

    enum Keys {
        static let model = "model"
        static let language = "language"
        static let autoCopy = "autoCopy"
        static let timestamps = "timestamps"
        static let pinnedPlayer = "pinnedPlayerLayout"
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
        static let showActions = "aiShowActions"
        static let exportIncludeInsights = "exportIncludeInsights"   // legacy boolean — migrated into exportContent
        static let exportContent = "exportContent"
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

    /// Default TTS backend: the system `AVSpeechSynthesizer` (cheap to construct + inert until called, like
    /// `TranscriptionEngine` — no XCTest gate needed; tests that exercise TTS inject a `NoopTTSService`).
    static func defaultTTS() -> any TTSService { SystemTTSService() }

    init(engine: any TranscribingEngine = TranscriptionEngine(),
         ai: any LocalLLMService = AppModel.defaultAI(),
         embedder: any TextEmbedder = AppModel.defaultEmbedder(),
         tts: any TTSService = AppModel.defaultTTS()) {
        self.engine = engine
        self.ai = ai
        self.embedder = embedder
        self.tts = tts
        let d = UserDefaults.standard
        selectedModel = d.string(forKey: Keys.model) ?? "openai_whisper-large-v3-v20240930_626MB"   // quantized turbo: best quality/size on RU (see bestDefault)
        language = d.string(forKey: Keys.language) ?? ""
        autoCopy = (d.object(forKey: Keys.autoCopy) as? Bool) ?? true
        showTimestamps = (d.object(forKey: Keys.timestamps) as? Bool) ?? true   // default ON: reveal the click-to-seek SegmentList
        pinnedPlayerLayout = (d.object(forKey: Keys.pinnedPlayer) as? Bool) ?? true   // default ON: pinned player + independent transcript scroll
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
        showActions = (d.object(forKey: Keys.showActions) as? Bool) ?? true
        // Export content mode (default: transcript). Migrate the legacy boolean (true → transcript+insights).
        if let raw = d.string(forKey: Keys.exportContent), let c = ExportContent(rawValue: raw) { exportContent = c }
        else { exportContent = d.bool(forKey: Keys.exportIncludeInsights) ? .withInsights : .transcript }
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
        if mlxDownloading { return true }               // downloading the ~2.3GB RU/UK model — hold the lane
        if embedDownloading { return true }             // downloading the semantic-search model — hold the lane
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

    /// The sidebar list: lexical (substring + lemma) matches, EXTENDED with download-tier semantic query→note
    /// matches the literal search missed — appended in relevance order below the exact matches. `semanticHitIDs` is
    /// computed asynchronously (debounced) so this stays synchronous + cheap; empty → today's pure-lexical list.
    var filteredHistory: [TranscriptItem] {
        let lexical = filterHistory(history, query: searchQuery, lemmaIndex: lemmaIndex)
        guard !semanticHitIDs.isEmpty else { return lexical }
        let lexicalIDs = Set(lexical.map(\.id))
        let semanticOnly = semanticHitIDs.compactMap { id in lexicalIDs.contains(id) ? nil : history.first { $0.id == id } }
        return lexical + semanticOnly
    }

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
