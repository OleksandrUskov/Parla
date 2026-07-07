import Foundation

/// Quick transcription without an open window (feature 03): from the clipboard, replaying the last file.
/// Remembering the «last source» is also triggered from the main `transcribe`.
extension AppModel {
    /// Triggered from a hotkey or the «Recognize from clipboard» button: grab the audio file from the clipboard and run.
    func quickTranscribeFromClipboard() {
        guard !isBusy, downloadingModel == nil else {
            QuickToast.shared.show(L("toast.busy"))
            return
        }
        let urls = clipboardAudioURLs()
        guard let first = urls.first else {
            QuickToast.shared.show(L("toast.clipboard.empty"))
            return
        }
        quickModeRun = true
        QuickToast.shared.show(Lf("toast.recognizing", first.lastPathComponent), sticky: true)
        handleDrop(urls: urls)   // existing entry point; it already guards against the double-launch race
    }

    /// Replay the last file (if it's still on disk).
    func transcribeLast() {
        guard !isBusy, downloadingModel == nil else { return }
        guard let url = resolveLastSource() else {
            QuickToast.shared.show(L("toast.last.unavailable"))
            return
        }
        quickModeRun = true
        QuickToast.shared.show(Lf("toast.repeating", url.lastPathComponent), sticky: true)
        handleDrop(urls: [url])
    }

    /// Remember the last successfully transcribed source (for «replay the last file»).
    func rememberSource(_ url: URL) {
        if let data = try? url.bookmarkData() {   // plain bookmark (the app is not sandboxed)
            UserDefaults.standard.set(data, forKey: Keys.lastBookmark)
        }
    }

    private func resolveLastSource() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: Keys.lastBookmark) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
