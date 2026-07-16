import Foundation

/// Handoff (NSUserActivity continuity) — "view this transcript on another device". Pure
/// Foundation, so Core stays UIKit/AppKit-free. Advertised on the reading surface (iOS `TranscriptDetailView` +
/// macOS `TranscriptCard`) and received on both roots; the type is declared in both apps' Info.plists
/// (NSUserActivityTypes). id-only, no payload — the note is opened locally by id.
extension AppModel {
    /// The NSUserActivity type for handing off the open transcript. Must match `NSUserActivityTypes` in both plists.
    public static let viewTranscriptActivityType = "com.parla.viewTranscript"

    /// Pure parser: a continuation's `userInfo` → the transcript id (nil if absent/malformed). Unit-testable.
    /// `nonisolated` — no actor state, so it's callable from any context (incl. the pure-logic tests).
    public nonisolated static func parseViewTranscriptActivity(_ userInfo: [AnyHashable: Any]?) -> UUID? {
        guard let raw = userInfo?["id"] as? String, let id = UUID(uuidString: raw) else { return nil }
        return id
    }

    /// Receive a Handoff continuation → route to the note via `pendingOpen`, the universal deep-link channel BOTH
    /// platforms drain (including on `.task`, so a COLD-LAUNCH continuation — the app wasn't running — isn't
    /// dropped). No-op if the id is absent or the note isn't on this device (id-only; nothing to show → ignored).
    public func continueViewTranscript(_ userInfo: [AnyHashable: Any]?) {
        guard let id = Self.parseViewTranscriptActivity(userInfo) else { return }
        pendingOpen = id
    }
}
