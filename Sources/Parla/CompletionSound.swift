import AppKit
import ParlaCore

/// A subtle built-in system sound when a transcription finishes — so background flows (hotkey,
/// folder-watch, menu-bar) feel finished even when the window isn't in focus. Best-effort:
/// `NSSound(named:)` returns nil if the named sound is unavailable, so `play()` is a safe no-op.
enum CompletionSound {
    /// Reached ONLY through `AppModel.playCompletionSound`, a seam whose Core default is inert and which only
    /// `AppModel.mac()` wires — so a unit test cannot get here at all. This used to carry its own
    /// `NSClassFromString("XCTestCase")` guard as a second line of defence; that put test-detection in the shipped
    /// binary to protect against a call path that does not exist.
    static func success() { NSSound(named: "Glass")?.play() }
    static func failure() { NSSound(named: "Basso")?.play() }
}
