import Foundation

/// One place for turning a URL the user picked into something that still works after a relaunch.
///
/// The app is not sandboxed today, and a plain bookmark is enough for that. Under the App Sandbox — which the
/// Mac App Store requires — it is not: a plain bookmark resolves to a URL the app has no permission to open, so
/// folder watching and "re-transcribe from the original" would come back after a restart pointing at files they
/// can no longer read. A security-scoped bookmark is what carries the user's grant across launches.
///
/// Two facts decided the shape of this, both measured rather than assumed:
///
/// 1. **A non-sandboxed process can create and resolve security-scoped bookmarks.** No entitlement is needed
///    outside the sandbox (inside it, `com.apple.security.files.bookmarks.app-scope` is). So there is no need for
///    two code paths keyed on the build — the same call works in the open-source build and the store build, and
///    the store build is then already correct on the day the entitlement is added.
/// 2. 🔴 **A plain bookmark cannot be resolved WITH `.withSecurityScope`** — it fails with
///    `NSCocoaErrorDomain 259, "isn't in the correct format"`. This is not academic: every bookmark already
///    stored in a user's `history.json` and `UserDefaults` is plain. Resolving only the new way would break the
///    watched folder and every record's source locator for everyone who has used the app before today.
///
/// Hence: write scoped and fall back to plain; read scoped and fall back to plain. Both directions degrade
/// instead of failing, which is the only way an already-installed app survives the change.
public enum Bookmarks {

    /// Make the most durable bookmark this process can. Best-effort by design — a bookmark is a *locator*, and
    /// every caller also keeps the plain path, so returning nil costs a fallback, not a feature.
    public static func make(for url: URL) -> Data? {
        if let scoped = try? url.bookmarkData(options: [.withSecurityScope],
                                              includingResourceValuesForKeys: nil, relativeTo: nil) {
            return scoped
        }
        return try? url.bookmarkData()
    }

    /// Resolve a bookmark written by any version of this app.
    ///
    /// When the data is security-scoped, access is STARTED here and the caller owns stopping it — that
    /// asymmetry is inherent to the API, so the `scoped` flag is the caller's cue and every consumer pairs it
    /// with `stopAccessingSecurityScopedResource()`. If starting access is refused, `scoped` is false: there is
    /// then nothing to stop, and reporting true would leak a balance the caller cannot satisfy.
    public static func resolve(_ data: Data) -> (url: URL, scoped: Bool)? {
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                              relativeTo: nil, bookmarkDataIsStale: &stale) {
            return (url, url.startAccessingSecurityScopedResource())
        }
        // Older installs stored plain bookmarks. They still locate the file; under a sandbox they simply will
        // not grant access, which is exactly the same position the app is in today.
        if let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) {
            return (url, false)
        }
        return nil
    }
}
