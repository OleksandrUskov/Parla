#if os(macOS)
import AppKit
import ParlaCore
import UniformTypeIdentifiers

/// macOS wiring for `AppModel`'s platform seams. The Core declares these behaviors as injectable closures with
/// inert Foundation-only defaults so it stays AppKit-free and ports to iOS; the macOS app installs the real
/// AppKit implementations here. iOS will provide its own wiring (UIPasteboard / `.fileExporter` / ShareLink)
/// against the same seams — this whole file stays macOS-only.
extension AppModel {
    /// The app-facing constructor: a default `AppModel` with macOS platform behavior wired into the seams.
    /// Unit tests keep the inert Core defaults (they never touch NSPasteboard / NSSavePanel / NSApplication).
    @MainActor static func mac() -> AppModel {
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

        // Freemium gate + StoreKit only in an official store build (`./build_app.sh --store` / Mac App Store add
        // the `ParlaStoreBuild` Info.plist key). A plain `./build_app.sh` (what someone who clones the public repo
        // runs) omits it → the FULL, ungated app.
        m.isStoreBuild = AppModel.storeBuildFlag(Bundle.main.object(forInfoDictionaryKey: AppModel.storeBuildInfoKey))

        // Audio decode / playback rendition → the in-process native decoder (Phase 2c native-first: opusfile +
        // AVAssetReader, same as iOS; no ffmpeg subprocess). webm/mkv/exotic containers are dropped by design
        // (AVFoundation can't demux Matroska).
        m.decoder = OpusAudioDecoder()

        m.copyToClipboard = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        m.isAppActive = { NSApplication.shared.isActive }

        m.clipboardAudioURLs = { PasteboardReader.audioOnly(PasteboardReader.fileURLs()) }

        m.presentSavePanel = { suggestedName, extensions in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedName
            panel.allowedContentTypes = extensions.map { UTType(filenameExtension: $0) ?? .plainText } + [.plainText]
            panel.canCreateDirectories = true
            return panel.runModal() == .OK ? panel.url : nil
        }

        // Transient UX: floating toast panel, completion sound, synthetic ⌘V paste.
        m.showToast = { text, sticky in QuickToast.shared.show(text, sticky: sticky) }
        m.hideToast = { QuickToast.shared.hide() }
        m.playCompletionSound = { success in success ? CompletionSound.success() : CompletionSound.failure() }
        m.attemptPaste = { PasteService.pasteIntoFrontmost() }
        m.pasteIsSelfFrontmost = { PasteService.isSelfFrontmost }
        m.requestPasteAccessibility = { PasteService.requestAccessibility() }
        m.pasteIsAvailable = { PasteService.isAvailable }

        // Folder-watch (macOS-only feature): wire the Core seams to the +FolderWatch impls.
        m.drainWatchQueue = { [weak m] in m?.drainQueue() }
        m.syncWatch = { [weak m] in m?.reapplyWatch() }

        return m
    }
}
#endif
