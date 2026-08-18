import Foundation
import ParlaCore

/// Quick transcription without an open window (feature 03): from the clipboard, replaying the last file.
/// Remembering the «last source» is also triggered from the main `transcribe`.
///
/// Toasts go through the `showToast` SEAM, which `AppModel.mac()` wires to `QuickToast`. This file used to call
/// the `QuickToast.shared` singleton directly — the only place in the codebase that bypassed the seam — which is
/// precisely why QuickToast needed its own "am I under test?" guard to avoid spawning a panel mid-suite.

/// The one security-scoped grant «replay the last file» keeps open, so the job can still open the file after
/// the resolve returns. File-scoped because an extension cannot add a stored property; the invariant it
/// enforces — at most one outstanding, a new one releases the old — lives in `SingleScopedGrant`, where it is
/// tested rather than asserted.
@MainActor private let heldReplayScope = SingleScopedGrant()

extension AppModel {
    /// Triggered from a hotkey or the «Recognize from clipboard» button: grab the audio file from the clipboard and run.
    func quickTranscribeFromClipboard() {
        guard !isBusy, downloadingModel == nil else {
            showToast(L("toast.busy"), false)
            return
        }
        let urls = clipboardAudioURLs()
        guard let first = urls.first else {
            showToast(L("toast.clipboard.empty"), false)
            return
        }
        quickModeRun = true
        showToast(Lf("toast.recognizing", first.lastPathComponent), true)
        handleDrop(urls: urls)   // existing entry point; it already guards against the double-launch race
    }

    /// Replay the last file (if it's still on disk).
    func transcribeLast() {
        guard !isBusy, downloadingModel == nil else { return }
        guard let url = resolveLastSource() else {
            showToast(L("toast.last.unavailable"), false)
            return
        }
        quickModeRun = true
        showToast(Lf("toast.repeating", url.lastPathComponent), true)
        handleDrop(urls: [url])
    }


    private func resolveLastSource() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Keys.lastBookmark),
              let (url, scoped) = Bookmarks.resolve(data) else { return nil }
        // 🔴 This used to release the grant immediately, with a comment saying that was free "today, while the
        // app is unsandboxed" and would become the signal that the scope needs holding once it wasn't. The Mac
        // App Store build is that moment: `transcribeLast` only ENQUEUES, and the decode opens the file
        // minutes later, so releasing here made every «replay the last file» — menu, hotkey, `parla://`,
        // Shortcut — fail after a relaunch in the store build.
        //
        // The original problem it solved was real, though: the async funnel has no idea it owes a stop, so
        // handing the grant to the caller leaked one per replay for the life of the process. So the grant is
        // held, but only ONE ever is: starting a new replay releases the previous one. That is long enough for
        // the job (a replay supersedes the one before it) and bounded at exactly one outstanding grant.
        guard FileManager.default.fileExists(atPath: url.path) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return nil
        }
        if scoped { heldReplayScope.hold(url) }
        return url
    }
}
