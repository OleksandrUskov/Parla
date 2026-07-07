import AppKit
import ParlaCore
import UniformTypeIdentifiers

/// Pulls file URLs out of the clipboard. Pure logic (`parse`/`audioOnly`) is decoupled from
/// I/O (`fileURLs`) so parsing can be unit-tested without a live NSPasteboard.
enum PasteboardReader {

    /// Read file URLs from the system pasteboard (main thread).
    @MainActor static func fileURLs(from pb: NSPasteboard = .general) -> [URL] {
        // 1) Direct path: Finder ⌘C puts NSURL objects on the pasteboard.
        if let objs = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let files = objs.filter { $0.isFileURL }
            if !files.isEmpty { return files }
        }
        // 2) Fallback: sometimes the pasteboard only holds a path string / file:// URL.
        let strings = pb.string(forType: .string).map { [$0] } ?? []
        return parse(strings: strings)
    }

    /// Pure string → file URL parser. Testable.
    static func parse(strings: [String]) -> [URL] {
        strings.compactMap { raw -> URL? in
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return nil }
            if s.hasPrefix("file://"), let u = URL(string: s), u.isFileURL { return u }
            if s.hasPrefix("/") { return URL(fileURLWithPath: s) }   // absolute POSIX path
            return nil
        }
    }

    /// Keep only what Parla can transcribe (by extension; single source of truth — AppModel.audioExts).
    static func audioOnly(_ urls: [URL]) -> [URL] {
        urls.filter { AppModel.audioExts.contains($0.pathExtension.lowercased()) }
    }
}
