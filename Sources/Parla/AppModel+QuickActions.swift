import Foundation
import ParlaCore

/// Quick transcription without an open window (feature 03): from the clipboard, replaying the last file.
/// Remembering the «last source» is also triggered from the main `transcribe`.
///
/// Toasts go through the `showToast` SEAM, which `AppModel.mac()` wires to `QuickToast`. This file used to call
/// the `QuickToast.shared` singleton directly — the only place in the codebase that bypassed the seam — which is
/// precisely why QuickToast needed its own "am I under test?" guard to avoid spawning a panel mid-suite.
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
        guard let data = UserDefaults.standard.data(forKey: Keys.lastBookmark) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
