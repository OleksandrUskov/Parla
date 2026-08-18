#if os(macOS)
import Foundation

/// Holds at most ONE security-scoped grant, releasing the previous one when a new one is taken.
///
/// It exists because of a bug worth remembering. «Replay the last file» resolved a bookmark, started the
/// grant, and released it before returning — with a comment saying that was free "today, while the app is
/// unsandboxed" and would become the signal that the scope needed holding once it wasn't. That moment arrived
/// with the Mac App Store build: the replay only ENQUEUES, and the decode opens the file minutes later, so
/// releasing at resolve time made every replay fail after a relaunch.
///
/// Handing the grant to the caller instead is what the original code was avoiding, and for good reason: the
/// async job funnel has no idea it owes a stop, so every replay leaked one grant for the life of the process.
/// This is the middle: the grant lives long enough for the job, and a replay supersedes the one before it, so
/// the number outstanding is bounded at one rather than at however many times the user pressed the key.
///
/// `stop` is injectable purely so the invariant is testable — `stopAccessingSecurityScopedResource()` is a
/// method on `URL` with no observable effect from the outside.
@MainActor
public final class SingleScopedGrant {
    private var held: URL?
    private let stop: (URL) -> Void

    public init(stop: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.stop = stop
    }

    /// The grant currently held, if any.
    public var current: URL? { held }

    /// Take `url` as the held grant, releasing whatever was held before. Re-holding the SAME url is a no-op
    /// rather than a stop-then-keep, because releasing a grant this object is about to keep would revoke it.
    public func hold(_ url: URL) {
        guard held != url else { return }
        if let old = held { stop(old) }
        held = url
    }

    /// Release the held grant, if any.
    public func release() {
        if let old = held { stop(old) }
        held = nil
    }
}
#endif
