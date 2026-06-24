import AppKit

/// A subtle built-in system sound when a transcription finishes — so background flows (hotkey,
/// folder-watch, menu-bar) feel finished even when the window isn't in focus. Best-effort:
/// `NSSound(named:)` returns nil if the named sound is unavailable, so `play()` is a safe no-op.
enum CompletionSound {
    static func success() { NSSound(named: "Glass")?.play() }
    static func failure() { NSSound(named: "Basso")?.play() }
}
