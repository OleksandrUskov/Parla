#if os(iOS)
import UIKit
import ParlaCore

/// iOS wiring for `AppModel`'s platform seams — the counterpart of the macOS `AppModel.mac()` factory. The Core
/// declares platform behaviors as injectable closures with inert Foundation-only defaults so it stays UI-toolkit
/// free; each app installs the real implementations. This keeps `AppModel` + `TranscriptionEngine` portable and
/// is what let the whole transcription path move to iOS unchanged.
extension AppModel {
    /// The iOS app-facing constructor: a default `AppModel` with the in-process decoder + UIKit seams wired in.
    /// The macOS-only seams (NSSavePanel export, synthetic ⌘V paste, folder-watch, the floating toast panel)
    /// deliberately keep their inert Core defaults — the iOS UI layer provides ShareLink / `.fileExporter`
    /// equivalents where they make sense. Unit tests that want the pure Core keep using `AppModel()` directly.
    @MainActor static func iOS() -> AppModel {
        // FIRST, before any store is read: an earlier install's library lives under a different folder
        // name, and `AppModel.init` loads history as a stored-property initializer. Migrating after that
        // would show the user an empty app and then quietly move their data in behind it.
        StorageRoot.migrateIfNeeded()
        // A resume record holds the TEXT of every completed chunk. Worth keeping for a few days so an
        // interrupted job can finish; not worth keeping forever beside the history it is invisible in.
        ChunkProgressStore.pruneIfStale()

        // The real AI + embedder are wired HERE, not guessed by the Core: the Core's defaults are inert
        // so a unit test can never load a real model by forgetting to inject one.
        let m = AppModel(ai: AppModel.productionAI(), embedder: AppModel.productionEmbedder())

        // iOS is distributed only via the App Store, so it's a store build (freemium gate on) — the `ParlaStoreBuild`
        // key is set in Parla-iOS-Info.plist. A dev can remove it for a full build.
        m.isStoreBuild = AppModel.storeBuildFlag(Bundle.main.object(forInfoDictionaryKey: AppModel.storeBuildInfoKey))

        // Audio decode / chunking → the in-process ParlaCore decoder (libopusfile + AVAssetReader). This is the
        // iOS replacement for the macOS ffmpeg subprocess and closes the drop → decode → WhisperKit pipeline.
        m.decoder = OpusAudioDecoder()

        // Launch-time sweep of abandoned import copies (failed-and-not-retried, cancelled-queued, crashed) — safe
        // here because nothing is in-flight/queued yet and lastAttemptedURLs is empty.
        AppModel.pruneImportedOrphans(keeping: m.history)

        m.copyToClipboard = { text in UIPasteboard.general.string = text }
        m.isAppActive = { UIApplication.shared.applicationState == .active }

        // Dictation + batch feedback → the iOS toast surface (macOS uses the QuickToast panel). Without this the
        // seams stay their Core no-op defaults and every dictation message (mic-denied, busy, failed, empty,
        // done/copied) + the batch-complete toasts are silently invisible on iOS.
        m.showToast = { text, sticky in ToastCenter.shared.show(text, sticky: sticky) }
        m.hideToast = { ToastCenter.shared.hide() }

        // Completion cue → system sound (macOS uses NSSound Glass/Basso). Gated by the soundOnComplete toggle
        // (default on, like macOS); unwired before, so that Settings toggle did nothing on iOS.
        m.playCompletionSound = { success in success ? CompletionSound.success() : CompletionSound.failure() }

        // RAM-adaptive default model — jetsam is the iOS ceiling, so pick the largest tier that fits this
        // device's live memory headroom, but ONLY when the user hasn't already chosen one. The bytes→variant
        // mapping is pure + unit-tested (ModelTierSelector); here we just feed it the live number.
        if UserDefaults.standard.string(forKey: "model") == nil {   // "model" == AppModel.Keys.model — no persisted choice
            let available = os_proc_available_memory()
            // 0 = the API is unavailable / returned unknown → keep the safe built-in default (626MB turbo) rather
            // than force the `base` floor. (A momentary-pressure mis-tier is recoverable via the model manager.)
            if available > 0 {
                m.selectedModel = ModelTierSelector.defaultModel(availableBytes: UInt64(available))
            }
        }

        return m
    }
}
#endif
