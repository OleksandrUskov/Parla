import Foundation

/// Быстрая расшифровка без открытого окна (фича 03): из буфера, повтор последнего файла.
/// Запоминание «последнего исходника» дёргается и из основного `transcribe`.
extension AppModel {
    /// Триггер из хоткея или кнопки «Распознать из буфера»: берём аудиофайл из буфера и запускаем.
    func quickTranscribeFromClipboard() {
        guard !isBusy, downloadingModel == nil else {
            QuickToast.shared.show(L("toast.busy"))
            return
        }
        let urls = PasteboardReader.audioOnly(PasteboardReader.fileURLs())
        guard let first = urls.first else {
            QuickToast.shared.show(L("toast.clipboard.empty"))
            return
        }
        quickModeRun = true
        QuickToast.shared.show(Lf("toast.recognizing", first.lastPathComponent), sticky: true)
        handleDrop(urls: urls)   // существующий вход; гонку двойного запуска он уже закрывает
    }

    /// Повторить последний файл (если он ещё на диске).
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

    /// Запомнить последний успешно расшифрованный исходник (для «повторить последний файл»).
    func rememberSource(_ url: URL) {
        if let data = try? url.bookmarkData() {   // обычный bookmark (приложение не в песочнице)
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
