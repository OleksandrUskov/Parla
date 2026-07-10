import Foundation

/// The verbs the `parla://` URL scheme understands. A pure value type so the parser is unit-testable.
/// Shared by the macOS handler (desktop automation — transcribe paths / clipboard) and the iOS handler
/// (deep-links — open a note, start dictation); each platform acts only on the verbs it supports. Relocated
/// into ParlaCore (iOS-port P2.3a) from the macOS-only `AppModel+URLScheme.swift` so both apps parse identically.
public enum ParlaURLCommand: Equatable, Sendable {
    case transcribe(paths: [String], dirs: [String])   // macOS: transcribe the named file/dir paths
    case transcribeLast                                 // macOS: re-run the last transcription
    case clipboard                                      // macOS: transcribe a path on the clipboard
    case note(id: UUID)                                 // iOS: open a specific transcript (widget / Handoff deep-link)
    case dictate                                        // iOS: start/stop dictation
    case show                                           // both: bring Parla forward / to History
    case unknown
}

/// Pure parser: `parla://<verb>?args` → command. No filesystem access (path validity/expansion is the caller's
/// job), so it slots straight into the pure-logic test suite. Query values are percent-decoded by URLComponents.
public func parseParlaURL(_ url: URL) -> ParlaURLCommand {
    guard url.scheme?.lowercased() == "parla" else { return .unknown }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    switch url.host?.lowercased() {
    case "transcribe":
        return .transcribe(paths: items.filter { $0.name == "path" }.compactMap(\.value),
                           dirs: items.filter { $0.name == "dir" }.compactMap(\.value))
    case "transcribe-last": return .transcribeLast
    case "clipboard":       return .clipboard
    case "note":
        // parla://note?id=<uuid> — open that transcript. A missing/malformed id → unknown (never a crash).
        guard let raw = items.first(where: { $0.name == "id" })?.value,
              let id = UUID(uuidString: raw) else { return .unknown }
        return .note(id: id)
    case "dictate":         return .dictate
    case "show":            return .show
    default:                return .unknown
    }
}
