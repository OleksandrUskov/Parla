import Foundation

/// Recovering the name the user actually shared.
///
/// The iOS Share Extension writes into ONE flat inbox directory, so it needs collision-free filenames and
/// stamps a UUID into each: `voice.ogg` becomes `voice-3F2504E0-…-0C6A.ogg`. That is correct for the inbox —
/// the atomic `.part` → rename handoff depends on a flat layout, and that handoff was itself a data-loss fix —
/// but the name then travelled all the way into the note. Two consequences, one cosmetic and one not:
///
/// - every note shared from iOS was titled `voice-<36 characters of hex>.ogg`;
/// - and long-audio RESUME could never match a re-share, because a job is identified by its source's name,
///   size and modification time, and the name was freshly random every time. The one path resume exists for —
///   a jetsam mid-job, then re-share the same voice note — was the one path it could not serve.
///
/// So the app strips the stamp when it copies out of the inbox. The match is deliberately strict: a trailing
/// hyphen followed by exactly a well-formed UUID, and nothing else. A user's own `report-v2.ogg` keeps its
/// name; only what this app added is removed.
public enum ShareInboxName {

    /// The name to give a copy of `component`, with the Share Extension's uniqueness stamp removed if present.
    public static func original(from component: String) -> String {
        let ext = (component as NSString).pathExtension
        let base = (component as NSString).deletingPathExtension
        // A UUID string is 36 characters, so the stamp is 37 with its hyphen — and there must be something left.
        guard base.count > 37 else { return component }
        let candidate = String(base.suffix(36))
        guard base.dropLast(36).hasSuffix("-"), UUID(uuidString: candidate) != nil else { return component }
        let stripped = String(base.dropLast(37))
        return ext.isEmpty ? stripped : stripped + "." + ext
    }
}
