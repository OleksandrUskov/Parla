import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// History: copy, inline edit (feature 02), delete, export to Markdown.
extension AppModel {
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyItem(_ item: TranscriptItem) {
        copy(item.display(timestamps: showTimestamps))
        lastCopiedID = item.id
        // «Copied» — brief highlight, then reset.
        let id = item.id
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if lastCopiedID == id { lastCopiedID = nil }
        }
    }

    /// Save the edited card text to history.
    /// Resolves the entry by `id` (not by a copy), stamps `edited`/`editedAt`, writes to disk.
    /// Returns true if the text actually changed (for UI feedback); a no-op edit → false.
    @discardableResult
    func saveEdit(_ rawText: String, for id: TranscriptItem.ID) -> Bool {
        guard let idx = history.firstIndex(where: { $0.id == id }) else { return false }
        let (newText, changed) = normalizedEdit(rawText, from: history[idx].text)
        guard changed else { return false }   // nothing meaningfully changed → don't write or stamp
        history[idx].text = newText
        history[idx].edited = true
        history[idx].editedAt = Date()
        HistoryStore.save(history)
        selection = id                        // keep the selection on the edited entry
        return true
    }

    func delete(_ item: TranscriptItem) {
        AudioStore.remove(item)                 // drop the audio copy along with the entry
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

    /// Export the entire history to a markdown file (save dialog).
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

    /// Export ONE transcript in the chosen format (save dialog). The format rendering is the pure
    /// `Export.swift` layer; this just runs the panel + writes, reusing `exportHistory`'s error path.
    func export(_ item: TranscriptItem, as format: ExportFormat) {
        let panel = NSSavePanel()
        let base = (item.sourceName as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText, .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = format == .json
                ? try exportJSON(item)
                : Data(exportString(item, as: format, timestamps: showTimestamps).utf8)
            try data.write(to: url)
        } catch {
            phase = .failed(Lf("error.save.failed", error.localizedDescription))
        }
    }
}
