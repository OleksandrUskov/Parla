import SwiftUI
import Foundation
import UniformTypeIdentifiers
import WhisperKit

/// How the dictation hotkey behaves: press once to start/stop (default) vs hold-to-talk (press-and-hold).
public enum DictationMode: String, CaseIterable, Identifiable {
    case toggle, hold
    public var id: String { rawValue }
    public var label: String { self == .hold ? L("settings.dictation.mode.hold") : L("settings.dictation.mode.toggle") }
}


/// The single `@Observable` view-model SwiftUI binds to. STATE and SETTINGS live here;
/// behavior is split across domain extensions:
/// `AppModel+Models` · `+Transcription` · `+FolderWatch` · `+QuickActions` · `+History` · `+AudioCache`.
/// Stored properties can't live in an extension, so cross-domain state is declared here and
/// shared with the extensions (which is why some of it is `internal` rather than `private`).
/// Type-erased handle for a file-system watcher, so Core can hold one without depending on the macOS-only
/// FSEvents `FolderWatcher` (which can't compile for iOS). The macOS app's `FolderWatcher` conforms; an iOS
/// build simply never sets `watcher`.
public protocol FileWatching: AnyObject {
    func start()
    func stop()
}

@MainActor
@Observable
public final class AppModel {
    public var phase: EnginePhase = .idle
    public var paywallReason: PaywallReason?          // non-nil → present the paywall (set by the free-tier length gate; the UI clears it on dismiss)
    /// non-nil → the model heard a different language than the user pinned, confidently enough to say so.
    /// Best-effort and dismissible: never blocks anything, never rewrites a transcript on its own.
    public var languageSuggestion: LanguageSuggestion?

    /// The in-flight decode's stop switch. Held here because the decode runs in a detached task that cannot see
    /// task cancellation, so this is the only channel the Cancel button has into it.
    @ObservationIgnored var decodeControl: DecodeControl?
    public var history: [TranscriptItem] = HistoryStore.load()
    public var selection: TranscriptItem.ID?
    public var pendingOpen: TranscriptItem.ID?        // a deep-link (parla://note / widget / Handoff) asked to open this note; drained by the History shell
    public var availableModels: [String] = []
    public var lastCopiedID: TranscriptItem.ID?
    public var lastAttemptedURLs: [URL] = []          // last input passed to transcribe — for «Try again» on failure
    public var downloadingModel: String?
    public var downloadProgress: Double = 0
    public var searchQuery: String = ""
    public var relatedIDs: [UUID] = []                         // "Related notes" to the OPEN item (doc↔doc semantic, P1) — recomputed on selection
    public var semanticHitIDs: [UUID] = []                     // download-tier query→note matches — blended into filteredHistory below the lexical hits
    @ObservationIgnored public var searchDebounce: Task<Void, Never>?   // debounces the semantic search on each keystroke
    @ObservationIgnored public var embeddingIndex: [UUID: Embedding] = [:]   // in-memory mirror of embeddings.json (doc↔doc related reads it; effect flows through observable relatedIDs)
    @ObservationIgnored public var enrichFailedIDs: Set<UUID> = []           // items whose generative enrich hard-failed this session — don't re-submit to the slow model every refresh (cleared on edit / next launch)
    public var lemmaIndex: [UUID: Set<String>] = [:]                         // per-item lemma set for morphology search; OBSERVED — filteredHistory depends on it, so it must re-evaluate when the index builds
    public var downloadedSet: Set<String> = []        // which models are on disk (reactive)
    public var modelSizes: [String: Int64] = [:]      // size of each downloaded model
    // MLX RU/UK generative model — separate opt-in download, distinct from the WhisperKit variants.
    public var mlxModelDownloaded: Bool = false       // RU/UK AI model present on disk (reactive)
    public var mlxModelBytes: Int64 = 0               // its on-disk size (for the "disk used" line)
    public var mlxDownloading: Bool = false           // single-flight + busy guard for the MLX download
    public var mlxDownloadProgress: Double = 0
    public var mlxDownloadError: String?              // last MLX download error — shown inline in the model row (cleared on retry/success)
    // Embedding model — opt-in download for query→note semantic search; distinct from the MLX LLM above.
    public var embedModelDownloaded: Bool = false     // semantic-search model present on disk (reactive)
    public var embedModelBytes: Int64 = 0             // its on-disk size (for the "disk used" line)
    public var embedDownloading: Bool = false         // single-flight + busy guard for the embed-model download
    public var embedDownloadProgress: Double = 0
    public var embedDownloadError: String?            // last embed-model download error — shown inline in the row

    // Settings (mirrored into UserDefaults).
    public var selectedModel: String { didSet { UserDefaults.standard.set(selectedModel, forKey: Keys.model) } }
    public var language: String { didSet { UserDefaults.standard.set(language, forKey: Keys.language) } }
    public var autoCopy: Bool { didSet { UserDefaults.standard.set(autoCopy, forKey: Keys.autoCopy) } }
    public var showTimestamps: Bool { didSet { UserDefaults.standard.set(showTimestamps, forKey: Keys.timestamps) } }
    /// Pinned-player reading layout: fixes the chrome + audio player and gives the transcript its OWN scroll (vs the
    /// classic single-scroll page). ON by default; the toggle is the instant, code-free rollback if it doesn't land.
    public var pinnedPlayerLayout: Bool { didSet { UserDefaults.standard.set(pinnedPlayerLayout, forKey: Keys.pinnedPlayer) } }
    public var translateToEnglish: Bool { didSet { UserDefaults.standard.set(translateToEnglish, forKey: Keys.translate) } }
    public var soundOnComplete: Bool { didSet { UserDefaults.standard.set(soundOnComplete, forKey: Keys.sound) } }

    // Folder watching (feature 04) — same didSet pattern for mirroring into UserDefaults.
    public var watchEnabled: Bool      { didSet { UserDefaults.standard.set(watchEnabled, forKey: Keys.watchEnabled); syncWatch() } }
    public var watchRecursive: Bool    { didSet { UserDefaults.standard.set(watchRecursive, forKey: Keys.watchRecursive); syncWatch() } }
    public var watchWriteSidecar: Bool { didSet { UserDefaults.standard.set(watchWriteSidecar, forKey: Keys.watchSidecar) } }
    public var globalHotkeyEnabled: Bool { didSet { UserDefaults.standard.set(globalHotkeyEnabled, forKey: Keys.hotkey) } }

    // Dictation — opt-in hotkey + whether to keep the recorded audio.
    public var dictationHotkeyEnabled: Bool { didSet { UserDefaults.standard.set(dictationHotkeyEnabled, forKey: Keys.dictationHotkey) } }
    public var keepDictationAudio: Bool { didSet { UserDefaults.standard.set(keepDictationAudio, forKey: Keys.keepDictationAudio) } }
    /// Paste the dictation result into the frontmost app (the ONLY Accessibility feature — off by default).
    public var dictationPasteIntoFrontmost: Bool { didSet { UserDefaults.standard.set(dictationPasteIntoFrontmost, forKey: Keys.dictationPaste) } }
    /// Hotkey behavior: press-to-toggle (default) vs hold-to-talk.
    public var dictationMode: DictationMode { didSet { UserDefaults.standard.set(dictationMode.rawValue, forKey: Keys.dictationMode) } }
    // AI insights, shown as editable fields in the card. Each is independently toggleable; ON by default.
    public var showTitles: Bool { didSet { UserDefaults.standard.set(showTitles, forKey: Keys.showTitles) } }
    public var showKeywords: Bool { didSet { UserDefaults.standard.set(showKeywords, forKey: Keys.showKeywords) } }
    public var showSummaries: Bool { didSet { UserDefaults.standard.set(showSummaries, forKey: Keys.showSummaries) } }
    public var showActions: Bool { didSet { UserDefaults.standard.set(showActions, forKey: Keys.showActions) } }
    /// What an export includes — transcript / transcript+insights / insights-only. Chosen via the export menu,
    /// remembered across launches (the export is a one-shot artifact, so the choice rides with the user, not the note).
    public var exportContent: ExportContent { didSet { UserDefaults.standard.set(exportContent.rawValue, forKey: Keys.exportContent) } }
    /// Auto-stop a dictation after a short run of silence (opt-in, off by default).
    public var dictationVADEnabled: Bool { didSet { UserDefaults.standard.set(dictationVADEnabled, forKey: Keys.dictationVAD) } }
    /// Live segment-level streaming preview while dictating (opt-in, off by default). PREVIEW ONLY — the
    /// saved transcript still comes from the full offline decode in `finishDictation`.
    public var dictationLiveStreaming: Bool { didSet { UserDefaults.standard.set(dictationLiveStreaming, forKey: Keys.dictationLiveStreaming) } }

    /// UI language — separate from the speech-recognition language (`language`). `.system` follows the OS.
    public var uiLanguage: UILanguage {
        didSet {
            UserDefaults.standard.set(uiLanguage.rawValue, forKey: Keys.uiLanguage)
            Localized.setLanguage(uiLanguage.code)
        }
    }

    /// Locale for SwiftUI `environment(\.locale)` (formatting + system controls).
    public var resolvedLocale: Locale { uiLanguage.locale }

    public var watchedFolderURL: URL?          // resolved from a bookmark — for displaying the path
    public var watchQueueCount: Int = 0        // how many files are waiting in the queue (for the status chip)

    // State shared with the extensions (can't be in an extension → internal, not private).
    public var quickModeRun = false                          // launched from hotkey/menu bar → toast on completion (+Transcription/+QuickActions)
    public var watcher: (any FileWatching)?                   // +FolderWatch (macOS FolderWatcher via the FileWatching seam)
    public var recorder: MicRecorder?                         // +Dictation (live mic capture)
    public var recordingStartedAt: Date?                      // +Dictation: non-nil while recording (drives isBusy + the chip timer)
    /// A stop arrived while the mic-permission prompt was still up, i.e. BEFORE `recordingStartedAt` existed.
    /// Without this the request was silently dropped and capture began with the hotkey already released — see
    /// `stopAndTranscribeDictation`. Cleared when a start claims the lane and when the pending start is abandoned.
    public var dictationStopRequested = false
    public var requestingMic = false                          // +Dictation: holds the lane during the mic-permission check,
                                                       // BEFORE any recording UI shows (recordingStartedAt stays nil)
    public var streamingTask: Task<Void, Never>?              // +DictationStream: the live decode loop (single-flight)
    public var dictationConfirmedText = ""                    // +DictationStream: stable streamed prefix (render solid)
    public var dictationHypothesisText = ""                   // +DictationStream: live streamed tail (render dimmed)
    public var refiningDictations: Set<UUID> = []             // +Dictation: items showing the streamed text while a full
                                                       // decode refines them (transient — never persisted, so a
                                                       // quit mid-refine just leaves the good streamed text)
    public var regeneratingIDs: Set<UUID> = []                // +Semantic: items whose insights are being re-generated on
                                                       // demand (the "Regenerate" button) — drives a per-note spinner.
                                                       // OBSERVED (not @ObservationIgnored) so the button updates;
                                                       // transient, never persisted. Off the isBusy lane (best-effort).
    public var summarizingChaptersIDs: Set<UUID> = []         // +Semantic: long notes whose per-chapter summaries are being
                                                       // generated on demand (the "Summarize chapters" button) — drives
                                                       // its spinner. OBSERVED; transient; off the isBusy lane (best-effort).
    public var summarizingChapters: Set<ChapterRef> = []      // +Semantic: individual chapters being re-generated on demand
                                                       // (per-chapter "regenerate" button) — drives each chapter's spinner.
    public var watchQueue: [URL] = []                         // waiting for transcription (single-flight)
    public var transcriptionQueue: [TranscriptionJob] = []    // manual drops waiting for the lane — stack "5, then 5 more"; shares the isBusy lane with watchQueue
    public var currentTranscriptionTask: Task<Void, Never>?   // the running MANUAL job — for Cancel (mirrors streamingTask); nil for watch/dictation runs
    public var cancelling = false                             // a cancel was requested; the in-flight file/chunk finishes before it stops ("Stopping…")
    public var lastSeen: [String: WatchedFileStat] = [:]      // snapshot of the previous pass (stability)
    public var processedKeys: [String] = []                   // FIFO order of processed dedupKeys
    public var processedSet: Set<String> = []                 // = Set(processedKeys), for O(1) lookups
    public var semanticRefreshInFlight = false                // single-flight guard for the semantic backfill
    public var semanticRefreshPending = false                 // a change arrived mid-refresh → run once more after

    public let engine: any TranscribingEngine                 // +Models (delete) / +Transcription (load+run) — injectable (test seam)
    public let ai: any LocalLLMService                         // Local-AI Layer seam — injectable; unused until P2 wires enrich
    public let embedder: any TextEmbedder                      // semantic-embedding seam — injectable; NLContextualEmbedding default
    public let tts: any TTSService                              // TTS seam (voice synthesis P1a) — injectable; SystemTTSService default (system voice)

    /// Audio decoding (platform + test seam): the inert Core default has no decoder wired in; both apps
    /// wire the in-process `OpusAudioDecoder` via `AppModel.mac()` / `AppModel.iOS()`. Tests
    /// inject a stub to script the decode.
    public var decoder: any AudioDecoding = UnavailableAudioDecoder()

    /// Completion-notification dispatch (test seam): real UNUserNotificationCenter in production;
    /// tests inject a no-op so they don't touch the notification center (no bundle proxy under XCTest).
    public var postNotification: (_ succeeded: Int, _ failed: Int) async -> Void = {
        await BatchNotifier.post(succeeded: $0, failed: $1)
    }

    /// Paste-into-frontmost (platform + test seam): macOS wires the real CGEvent ⌘V (`PasteService`) via
    /// `AppModel.mac()`; the inert Core/test default reports "not pasted". Returns whether a synthetic paste
    /// was actually performed (false → not Accessibility-trusted).
    public var attemptPaste: @MainActor () -> Bool = { false }

    /// Whether Parla itself is frontmost — dictation skips synthetic paste into our OWN window (it would land in
    /// the search / edit field). macOS wires `PasteService.isSelfFrontmost`; inert default false (iOS has no
    /// paste-into-frontmost, and the feature's toggle is macOS-only, so this path is dead there anyway).
    public var pasteIsSelfFrontmost: @MainActor () -> Bool = { false }

    /// One-time Accessibility prompt when paste-into-frontmost is enabled but not yet trusted. macOS wires
    /// `PasteService.requestAccessibility`; inert default is a no-op.
    public var requestPasteAccessibility: @MainActor () -> Void = { }

    // MARK: Platform seams
    // AppModel is Core-bound — it must stay AppKit-free so it ports to iOS. Each platform behavior below is an
    // injectable closure with an INERT Foundation-only default; the macOS app installs the real AppKit behavior
    // through `AppModel.mac()` (see AppModel+PlatformMac.swift). iOS will wire UIKit equivalents.

    /// Clipboard write: macOS wires `NSPasteboard`; inert default is a no-op (Core + tests stay AppKit-free).
    public var copyToClipboard: @MainActor (String) -> Void = { _ in }

    /// Whether the app window is frontmost — gates the batch-completion notification. macOS wires
    /// `NSApplication.shared.isActive`; the inert default reports "not frontmost" (matches the headless/XCTest reality).
    public var isAppActive: @MainActor () -> Bool = { false }

    /// Audio file URLs currently on the clipboard (drives «recognize from clipboard»): macOS wires
    /// `PasteboardReader`; inert default is empty.
    public var clipboardAudioURLs: @MainActor () -> [URL] = { [] }

    /// Present a save dialog and return the chosen destination (or nil if cancelled): macOS wires `NSSavePanel`.
    /// The data production + write + error handling stay in Core — only the file-picker UI is platform-specific.
    public var presentSavePanel: @MainActor (_ suggestedName: String, _ extensions: [String]) -> URL? = { _, _ in nil }

    /// Show a transient toast (macOS: `QuickToast` floating panel; iOS: its own overlay). `sticky` keeps it up
    /// until `hideToast`. Inert default is a no-op — the transcription result path stays platform-agnostic.
    public var showToast: @MainActor (_ text: String, _ sticky: Bool) -> Void = { _, _ in }

    /// Dismiss a sticky toast (macOS: `QuickToast.hide`). Inert default is a no-op.
    public var hideToast: @MainActor () -> Void = { }

    /// Play the batch-completion sound (macOS: `NSSound` Glass/Basso via `CompletionSound`). Inert default no-op.
    public var playCompletionSound: @MainActor (_ success: Bool) -> Void = { _ in }

    /// Drain the folder-watch queue (macOS-only feature; the impl lives in the app's +FolderWatch). Inert no-op so
    /// `pumpQueues` in Core stays platform-agnostic — an iOS build simply has no folder watching.
    public var drainWatchQueue: @MainActor () -> Void = { }

    /// Re-apply the folder-watch config after a settings change (start/stop/restart the FSEvents watcher). macOS wires it.
    public var syncWatch: @MainActor () -> Void = { }

    // MARK: Monetization seams (Phase 3)

    /// True ONLY in an official store build (the freemium gate + Pro upsell UI are enabled). A from-source / dev
    /// build leaves this false → the FULL app: no length cap, no feature gating, no Pro/paywall UI, no StoreKit.
    /// Set by the app factory (`mac()`/`iOS()`) from the `ParlaStoreBuild` Info.plist key (`./build_app.sh --store`
    /// / iOS adds it; the default macOS build omits it). Per the repo decision that a self-compiled build is the
    /// immaterial honor-system "leak" (normal users buy from the store; open-source builders get the full app), so
    /// nothing is crippled for someone who clones + builds the public repo.
    public var isStoreBuild = false

    /// Whether the user owns Pro (the monetization entitlement). Injected: in a STORE build both apps wire it to
    /// the live `PurchaseManager` entitlement; otherwise it stays `true` — the inert Core/test default, fail-OPEN,
    /// so a from-source build (or a wiring gap) is the FULL app. A test that exercises the free tier sets `{ false }`.
    public var isProUser: @MainActor () -> Bool = { true }

    /// Cheap container-duration probe for the free-tier length gate (reads the media index, no decode). Ogg/Opus
    /// (incl. extension-less Telegram voices) can't be read by AVFoundation → probe via opusfile's `op_pcm_total`
    /// first; everything else via `AVURLAsset`. Injected so tests can script a duration without a real fixture.
    public var mediaDuration: @Sendable (URL) async -> Double? = { url in
        if let d = OpusAudioDecoder.oggDurationSeconds(url) { return d }
        return await MediaDuration.seconds(of: url)
    }

    public enum Keys {
        public static let model = "model"
        public static let language = "language"
        public static let autoCopy = "autoCopy"
        public static let timestamps = "timestamps"
        public static let pinnedPlayer = "pinnedPlayerLayout"
        public static let sound = "soundOnComplete"
        public static let translate = "translateToEnglish"
        public static let watchEnabled = "watchEnabled"
        public static let watchRecursive = "watchRecursive"
        public static let watchSidecar = "watchWriteSidecar"
        public static let watchBookmark = "watchBookmark"
        public static let hotkey = "globalHotkeyEnabled"
        public static let dictationHotkey = "dictationHotkeyEnabled"
        public static let keepDictationAudio = "keepDictationAudio"
        public static let dictationPaste = "dictationPasteIntoFrontmost"
        public static let dictationPasteAXPrompted = "dictationPasteAXPrompted"   // one-time AX prompt guard
        public static let dictationMode = "dictationMode"
        public static let showTitles = "aiShowTitles"
        public static let showKeywords = "aiShowKeywords"
        public static let showSummaries = "aiShowSummaries"
        public static let showActions = "aiShowActions"
        public static let exportIncludeInsights = "exportIncludeInsights"   // legacy boolean — migrated into exportContent
        public static let exportContent = "exportContent"
        public static let dictationVAD = "dictationVADEnabled"
        public static let dictationLiveStreaming = "dictationLiveStreaming"
        public static let lastBookmark = "lastSourceBookmark"
        public static let uiLanguage = "uiLanguage"
    }

    /// Default embedder: the real on-device `NLEmbedder` in production, a `NoopEmbedder` under unit tests — so a
    /// test that doesn't inject a fake never loads the `NLContextualEmbedding` model or downloads its assets, and
    /// the kicked refresh stays instant (same `XCTestCase` headless gate as `PasteService`/`CompletionSound`).
    public static func defaultEmbedder() -> any TextEmbedder {
        NSClassFromString("XCTestCase") != nil ? NoopEmbedder() : NLEmbedder()
    }

    /// Default AI backend: the real `DefaultAIService` in production, a `NoopAIService` under unit tests — so a
    /// test that doesn't inject a fake never calls the real on-device FoundationModels session (slow + non-deterministic).
    public static func defaultAI() -> any LocalLLMService {
        NSClassFromString("XCTestCase") != nil ? NoopAIService() : DefaultAIService()
    }

    /// Default TTS backend: the system `AVSpeechSynthesizer` (cheap to construct + inert until called, like
    /// `TranscriptionEngine` — no XCTest gate needed; tests that exercise TTS inject a `NoopTTSService`).
    public static func defaultTTS() -> any TTSService { SystemTTSService() }

    public init(engine: any TranscribingEngine = TranscriptionEngine(),
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

    // MARK: - Memory pressure

    @ObservationIgnored private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    /// Start listening for the system's own "memory is tight" signal and give the transcription weights back
    /// when it fires. Call once at launch.
    ///
    /// Why this exists: the engine loads its model on first use and kept it forever, because nothing ever called
    /// `unload()`. Unloading on a timer (or after every note) would trade a real, felt reload delay for memory
    /// nobody was short of — so the trigger is the OS telling us it actually needs the memory back, and only
    /// while no job is running.
    public func startMemoryPressureMonitor() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in await self?.releaseIdleMemory() }
        }
        source.resume()
        memoryPressureSource = source
    }

    /// Hand the model's memory back if — and only if — nothing is running. Separated from the dispatch source
    /// so the policy itself is testable without provoking real memory pressure.
    public func releaseIdleMemory() async {
        guard !isBusy else { return }   // never yank the model out from under a running job
        await engine.unload()
    }

    public var isBusy: Bool {
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
    public var shouldConfirmQuit: Bool {
        if recordingStartedAt != nil || downloadingModel != nil { return true }
        return isBusy && refiningDictations.isEmpty
    }

    /// Item for the right pane — taken from the VISIBLE (filtered) list, so the pane and
    /// the sidebar don't diverge while a search is active.
    public var selectedItem: TranscriptItem? {
        if let id = selection, let found = filteredHistory.first(where: { $0.id == id }) { return found }
        return filteredHistory.first
    }

    /// The sidebar list: lexical (substring + lemma) matches, EXTENDED with download-tier semantic query→note
    /// matches the literal search missed — appended in relevance order below the exact matches. `semanticHitIDs` is
    /// computed asynchronously (debounced) so this stays synchronous + cheap; empty → today's pure-lexical list.
    public var filteredHistory: [TranscriptItem] {
        let lexical = filterHistory(history, query: searchQuery, lemmaIndex: lemmaIndex)
        guard !semanticHitIDs.isEmpty else { return lexical }
        let lexicalIDs = Set(lexical.map(\.id))
        let semanticOnly = semanticHitIDs.compactMap { id in lexicalIDs.contains(id) ? nil : history.first { $0.id == id } }
        return lexical + semanticOnly
    }

    /// Most recent transcript's text, or "" — the read value behind GetLastTranscriptIntent (Shortcuts).
    public var lastTranscriptText: String { history.first?.text ?? "" }

    // «What counts as audio» — a cross-domain utility (used by transcription, watching, and the buffer).
    // Phase 2c (native-first decode) dropped webm/mkv — AVFoundation cannot demux Matroska/WebM, so advertising
    // them would only hard-fail at decode time. `amr` was dropped in the same sweep on the assumption that
    // AVFoundation had no AMR decoder; measured, it does — a synthesised .amr reports 1 track / 3.02 s and decodes
    // through Lane 2 — and `.3gp` (the same codec family) was kept anyway, so the drop was also self-inconsistent.
    public nonisolated static let audioExts: Set<String> = [
        "ogg", "oga", "opus", "m4a", "mp3", "wav", "aac", "flac", "amr",
        "mp4", "mov", "m4v", "3gp", "aiff", "aif", "caf",
    ]

    /// Formats AVFoundation opens directly — WhisperKit loads audio via `AVAudioFile(forReading:)` and
    /// resamples to 16 kHz itself, so these can go straight to the engine with NO ffmpeg re-encode.
    /// Conservative v1 = the EXACT mirror of the prod-proven `AudioStore.directlyPlayable` (pure-audio
    /// containers). Video containers (mp4/mov/m4v) deliberately stay OFF this list — they route through the
    /// decoder's AVAssetReader lane (Phase 2c: native in-process; was ffmpeg). Must remain a strict subset of
    /// `audioExts` (pinned by test): a format wrongly listed here would hard-fail instead of routing through the decoder.
    public nonisolated static let avDecodable: Set<String> = ["m4a", "mp3", "wav", "aac", "caf", "aiff", "aif"]

    /// Placeholder extension the iOS Share Extension assigns when a shared item carries none — it can't link
    /// ParlaCore (extension memory budget), so it can't sniff the content itself.
    public nonisolated static let opaqueExtension = "dat"

    /// Whether a file should be OFFERED to the transcription pipeline. A known audio extension qualifies; so does
    /// a file with NO extension (or the share-inbox `.dat` placeholder) whose header sniffs as Ogg.
    ///
    /// Telegram routinely saves voice messages WITHOUT an extension, and the decoder already routes those by
    /// content (`OggS` magic) — but every INTAKE filter used to reject them by name first, so an extension-less
    /// voice note was silently ignored by the `parla://` verb, the clipboard/Services action, folder-watch, a
    /// dropped folder, and the iOS share inbox (where it lands as `.dat` and would sit there forever). A direct
    /// drag-drop of the file worked, which is why this stayed invisible. Anything with a REAL but unsupported
    /// extension is still rejected by name (no sniffing `.txt`), so the guard stays tight.
    public nonisolated static func isTranscribable(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if audioExts.contains(ext) { return true }
        guard ext.isEmpty || ext == opaqueExtension else { return false }
        return OpusAudioDecoder.looksLikeOgg(url)
    }

    public nonisolated static func audioFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return en.compactMap { $0 as? URL }
            .filter { isTranscribable($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
