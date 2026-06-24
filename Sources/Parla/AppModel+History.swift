import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// История: копирование, инлайн-правка (фича 02), удаление, экспорт в Markdown.
extension AppModel {
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyItem(_ item: TranscriptItem) {
        copy(item.display(timestamps: showTimestamps))
        lastCopiedID = item.id
        // «Скопировано» — кратковременная подсветка, сбрасываем.
        let id = item.id
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if lastCopiedID == id { lastCopiedID = nil }
        }
    }

    /// Сохранить отредактированный текст карточки в историю.
    /// Резолвит запись по `id` (а не по копии), штампует `edited`/`editedAt`, пишет на диск.
    /// Возвращает true, если текст реально изменился (для UI-фидбэка); no-op правка → false.
    @discardableResult
    func saveEdit(_ rawText: String, for id: TranscriptItem.ID) -> Bool {
        guard let idx = history.firstIndex(where: { $0.id == id }) else { return false }
        let (newText, changed) = normalizedEdit(rawText, from: history[idx].text)
        guard changed else { return false }   // ничего по сути не поменялось → не пишем и не штампуем
        history[idx].text = newText
        history[idx].edited = true
        history[idx].editedAt = Date()
        HistoryStore.save(history)
        selection = id                        // держим выделение на отредактированной записи
        return true
    }

    func delete(_ item: TranscriptItem) {
        AudioStore.remove(item)                 // снести копию аудио вместе с записью
        history.removeAll { $0.id == item.id }
        if selection == item.id { selection = nil }
        HistoryStore.save(history)
    }

    func clearHistory() {
        history.forEach(AudioStore.remove)
        history.removeAll()
        selection = nil
        HistoryStore.save(history)
    }

    /// Экспорт всей истории в markdown-файл (диалог сохранения).
    func exportHistory() {
        guard !history.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "parla-history.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText, .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(exportText(history).utf8).write(to: url)
        } catch {
            phase = .failed(Lf("error.save.failed", error.localizedDescription))
        }
    }
}
