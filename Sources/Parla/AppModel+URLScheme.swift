import AppKit
import ParlaCore

/// `parla://` URL scheme (OS_INTEGRATION). Lets Raycast/Alfred/terminal/Stream Deck/Shortcuts drive
/// Parla. Every verb funnels into the existing race-safe `handleDrop` / quick-action entry points —
/// zero new transcription logic.
extension AppModel {
    func handleParlaURL(_ url: URL) {
        switch parseParlaURL(url) {
        case .transcribe(let paths, let dirs):
            // SECURITY/backstop: a parla:// link can name ANY path. Accept only EXISTING audio files or
            // directories, read-only — handleDrop's own audioExts/audioFiles filter is the final guard.
            let urls = (paths + dirs).map { URL(fileURLWithPath: $0) }.filter { u in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { return false }
                return isDir.boolValue || Self.audioExts.contains(u.pathExtension.lowercased())
            }
            guard !urls.isEmpty else { return }
            quickModeRun = true            // toast feedback, no window assumed (like the hotkey path)
            handleDrop(urls: urls)
        case .transcribeLast: transcribeLast()                 // already sets quickModeRun
        case .clipboard:      quickTranscribeFromClipboard()   // already sets quickModeRun
        case .show:           NSApp.activate()                 // "open Parla" keyword for Alfred/Raycast
        case .unknown:        break                            // ignore silently
        }
    }
}

/// The verbs the `parla://` scheme understands. A pure value type so the parser is unit-testable.
enum ParlaURLCommand: Equatable {
    case transcribe(paths: [String], dirs: [String])
    case transcribeLast
    case clipboard
    case show
    case unknown
}

/// Pure parser: `parla://<verb>?args` → command. No filesystem access (path validity/expansion is the
/// caller's job), so it slots straight into the pure-logic test suite. Query values are
/// percent-decoded by URLComponents.
func parseParlaURL(_ url: URL) -> ParlaURLCommand {
    guard url.scheme?.lowercased() == "parla" else { return .unknown }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    switch url.host?.lowercased() {
    case "transcribe":
        return .transcribe(paths: items.filter { $0.name == "path" }.compactMap(\.value),
                           dirs: items.filter { $0.name == "dir" }.compactMap(\.value))
    case "transcribe-last": return .transcribeLast
    case "clipboard":       return .clipboard
    case "show":            return .show
    default:                return .unknown
    }
}
