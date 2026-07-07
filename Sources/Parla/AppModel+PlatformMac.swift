#if os(macOS)
import AppKit
import ParlaCore
import UniformTypeIdentifiers

/// macOS wiring for `AppModel`'s platform seams. The Core declares these behaviors as injectable closures with
/// inert Foundation-only defaults so it stays AppKit-free and ports to iOS; the macOS app installs the real
/// AppKit implementations here. iOS will provide its own wiring (UIPasteboard / `.fileExporter` / ShareLink)
/// against the same seams — this whole file stays macOS-only (see IOS_PORT.md §1).
extension AppModel {
    /// The app-facing constructor: a default `AppModel` with macOS platform behavior wired into the seams.
    /// Unit tests keep the inert Core defaults (they never touch NSPasteboard / NSSavePanel / NSApplication).
    @MainActor static func mac() -> AppModel {
        let m = AppModel()

        // Audio decode / playback rendition → vendored ffmpeg (Process). macOS-only; iOS injects its own.
        m.decoder = FFmpegAudioDecoder()

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

        // Folder-watch (macOS-only feature): wire the Core seams to the +FolderWatch impls.
        m.drainWatchQueue = { [weak m] in m?.drainQueue() }
        m.syncWatch = { [weak m] in m?.reapplyWatch() }

        return m
    }
}
#endif
