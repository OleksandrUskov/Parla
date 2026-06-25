import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Optional paste-into-frontmost for dictation — the ONLY feature in Parla that touches Accessibility,
/// and it's strictly opt-in (off by default). It synthesizes a SINGLE ⌘V into the frontmost app via
/// `CGEvent`; it does NOT install a global event tap and does NOT log keystrokes. The dictated text is
/// always placed on the clipboard first, so even without Accessibility the user can paste manually.
enum PasteService {
    /// True when XCTest is loaded — so the synthetic paste / Accessibility prompt can NEVER fire during
    /// unit tests (mirrors `CompletionSound` / `QuickToast`). Belt-and-suspenders to the AppModel seam.
    private static var isHeadless: Bool { NSClassFromString("XCTestCase") != nil }

    /// Whether we're allowed to synthesize a paste (Accessibility trust granted). Cheap; safe anytime.
    static var canPaste: Bool { AXIsProcessTrusted() }

    /// Whether Parla itself is the frontmost app — a synthetic ⌘V would then land in OUR own window
    /// (e.g. dictation stopped via the in-window button), so the caller skips the paste. Headless-guarded
    /// so the unit-test seam stays exercised (a `swift test` process is never frontmost).
    static var isSelfFrontmost: Bool {
        guard !isHeadless else { return false }
        return NSRunningApplication.current.isActive
    }

    /// Prompt for Accessibility + reveal the System Settings pane. Call ONLY when the user has opted into
    /// auto-paste and isn't trusted yet — NEVER on launch / unprompted (macOS shows the dialog once).
    @discardableResult
    static func requestAccessibility() -> Bool {
        guard !isHeadless else { return false }
        // `kAXTrustedCheckOptionPrompt` is a non-Sendable global `var` → referencing it errors under
        // Swift 6 strict concurrency. Its documented value is this literal, so use it directly.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Synthesize one ⌘V into the frontmost app. No-op (returns false) if Accessibility isn't granted.
    /// One synthetic key-chord, posted once — not a tap, not a logger.
    @discardableResult
    static func pasteIntoFrontmost() -> Bool {
        guard !isHeadless, canPaste else { return false }
        let src = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 0x09   // ANSI 'V'
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
