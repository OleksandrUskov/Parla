import AppKit

/// A subtle built-in system sound when a transcription finishes — so background flows (hotkey,
/// folder-watch, menu-bar) feel finished even when the window isn't in focus. Best-effort:
/// `NSSound(named:)` returns nil if the named sound is unavailable, so `play()` is a safe no-op.
enum CompletionSound {
    /// True when XCTest is loaded into the process — so the sound can NEVER fire during unit tests,
    /// regardless of any call-site forgetting to disable it. Belt-and-suspenders to the per-call
    /// soundOnComplete gating. (NSClassFromString works under both `swift test` and Xcode, unlike the
    /// Xcode-only XCTestConfigurationFilePath env var.)
    static var isHeadless: Bool { NSClassFromString("XCTestCase") != nil }

    static func success() { guard !isHeadless else { return }; NSSound(named: "Glass")?.play() }
    static func failure() { guard !isHeadless else { return }; NSSound(named: "Basso")?.play() }
}
