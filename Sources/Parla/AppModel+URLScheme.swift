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
        case .note(let id):   selection = id; NSApp.activate()  // deep-link to a note (also reachable on iOS)
        case .dictate:        toggleDictation()                // start/stop dictation
        case .show:           NSApp.activate()                 // "open Parla" keyword for Alfred/Raycast
        case .unknown:        break                            // ignore silently
        }
    }
}

// The `parla://` parser + `ParlaURLCommand` moved to ParlaCore (`ParlaURL.swift`, iOS-port P2.3a) so the iOS app
// parses the same verbs; this file keeps only the macOS-flavoured handler (AppKit activation + path transcription).
