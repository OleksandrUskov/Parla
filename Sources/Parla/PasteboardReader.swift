import AppKit
import UniformTypeIdentifiers

/// Достаёт файловые URL из буфера обмена. Чистая логика (`parse`/`audioOnly`) отделена от
/// ввода-вывода (`fileURLs`), чтобы парсинг покрывался юнит-тестами без живого NSPasteboard.
enum PasteboardReader {

    /// Прочитать файловые URL из системного буфера (главный поток).
    @MainActor static func fileURLs(from pb: NSPasteboard = .general) -> [URL] {
        // 1) Прямой путь: Finder ⌘C кладёт NSURL-объекты.
        if let objs = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let files = objs.filter { $0.isFileURL }
            if !files.isEmpty { return files }
        }
        // 2) Фолбэк: иногда в буфере только строка с путём / file://-URL.
        let strings = pb.string(forType: .string).map { [$0] } ?? []
        return parse(strings: strings)
    }

    /// Чистый парсер строк → файловые URL. Тестируемо.
    static func parse(strings: [String]) -> [URL] {
        strings.compactMap { raw -> URL? in
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }
            if s.hasPrefix("file://"), let u = URL(string: s), u.isFileURL { return u }
            if s.hasPrefix("/") { return URL(fileURLWithPath: s) }   // абсолютный POSIX-путь
            return nil
        }
    }

    /// Оставить только то, что Parla умеет расшифровывать (по расширению; единый источник — AppModel.audioExts).
    static func audioOnly(_ urls: [URL]) -> [URL] {
        urls.filter { AppModel.audioExts.contains($0.pathExtension.lowercased()) }
    }
}
