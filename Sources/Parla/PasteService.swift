import Foundation
import ParlaCore
import AppKit
import ApplicationServices
import CoreGraphics

/// Optional paste-into-frontmost for dictation — the ONLY feature in Parla that touches Accessibility,
/// and it's strictly opt-in (off by default). It synthesizes a SINGLE ⌘V into the frontmost app via
/// `CGEvent`; it does NOT install a global event tap and does NOT log keystrokes. The dictated text is
/// always placed on the clipboard first, so even without Accessibility the user can paste manually.
///
/// Every entry point here is reached ONLY through an `AppModel` seam (`attemptPaste` / `pasteIsSelfFrontmost` /
/// `requestPasteAccessibility`) whose Core default is inert and which only `AppModel.mac()` wires. A unit test
/// therefore cannot synthesize a ⌘V into the developer's frontmost app — it gets that guarantee from the seam,
/// not from shipped code inspecting its own process for XCTest.
enum PasteService {
    /// Whether we're allowed to synthesize a paste. Cheap; safe anytime.
    ///
    /// A sandboxed build can never be: Accessibility trust is not available to a containerised process, so
    /// `AXIsProcessTrusted()` stays false and every paste would be a silent no-op. Reporting it up front lets
    /// the UI hide the toggle instead of offering a switch that does nothing when flipped.
    static var canPaste: Bool { !Sandbox.isActive && AXIsProcessTrusted() }

    /// Whether the feature exists at all on this build. Distinct from `canPaste`, which is about PERMISSION:
    /// unavailable means "there is nothing to grant", and the difference is what the user needs told.
    static var isAvailable: Bool { !Sandbox.isActive }

    /// Whether Parla itself is the frontmost app — a synthetic ⌘V would then land in OUR own window
    /// (e.g. dictation stopped via the in-window button), so the caller skips the paste.
    static var isSelfFrontmost: Bool { NSRunningApplication.current.isActive }

    /// Prompt for Accessibility + reveal the System Settings pane. Call ONLY when the user has opted into
    /// auto-paste and isn't trusted yet — NEVER on launch / unprompted (macOS shows the dialog once).
    @discardableResult
    static func requestAccessibility() -> Bool {
        // `kAXTrustedCheckOptionPrompt` is a non-Sendable global `var` → referencing it errors under
        // Swift 6 strict concurrency. Its documented value is this literal, so use it directly.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Synthesize one ⌘V into the frontmost app. No-op (returns false) if Accessibility isn't granted.
    /// One synthetic key-chord, posted once — not a tap, not a logger.
    @discardableResult
    static func pasteIntoFrontmost() -> Bool {
        guard canPaste else { return false }
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
