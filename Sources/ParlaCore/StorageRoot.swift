import Foundation

/// The one directory everything this app owns lives under, and the reason it is named after the bundle
/// identifier rather than after the app.
///
/// ⚠️ **The reason originally written here was wrong, and the correction matters more than the rename.** This
/// said that when a previously-unsandboxed app becomes sandboxed the system migrates its data into the new
/// container **by bundle identifier**, so naming the directory `com.parla.app` would let the Mac App Store
/// build inherit the user's library. That was hedged at the time as "the matching rules are Apple's, not ours".
/// It has since been MEASURED on macOS 26, three independent ways — a never-launched app, an app run
/// unsandboxed and then sandboxed (the real upgrade path), and a LaunchServices launch. **macOS does not
/// migrate `Application Support/<bundle-id>` at all**; the container's `RedirectedPaths` is empty every time.
/// Only `Preferences/<bundle-id>.plist` comes across. The rename therefore buys ZERO migration, and a store
/// build left to the system would arrive configured and empty.
///
/// The rename stays, for the reasons that were always true independently: naming a store directory after the
/// bundle identifier is the convention, it is what makes the container path and the loose path agree, and it
/// gives the rebrand one place to hook. What carries the library across is `SandboxHandoff`, which stages it
/// into the container deliberately — read that file for what the system actually does.
///
/// The name is read from the running bundle rather than hardcoded, so a future rename of the app changes this
/// with it and cannot be forgotten. What DOES have to be remembered is adding the outgoing identifier to
/// `legacyFolderNames` in the same commit — recorded in REBRAND.md.
public enum StorageRoot {

    /// `nonisolated(unsafe)`: the same deliberate global-mutable opt-out as `HistoryStore.fileURL` — a test seam,
    /// written only in setup, read widely. Production never changes it after launch.
    /// The LIVE root. Redirected by test setup, so anything that reads it in a test writes to a temp tree.
    nonisolated(unsafe) public static var url: URL = defaultURL()

    /// Folder names this app has used before, newest first. `migrateIfNeeded` moves the first one it finds.
    /// ⚠️ A rebrand changes the bundle identifier, and therefore this directory — add the OUTGOING identifier
    /// here in the same commit or the user's entire library is left behind under a name nothing looks for.
    public static let legacyFolderNames = ["Parla"]

    /// The PRODUCTION root, computed fresh and never redirected — deliberately separate from `url`.
    ///
    /// Each store exposes a `default…()` built on this, so a test can assert where data belongs in production
    /// WHILE the live path points somewhere harmless. Collapsing the two would silently turn those assertions
    /// into "the redirect works", which is a thing they already know. Two of them went red when this was first
    /// written as one value, which is the only reason it is two now.
    public static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        // Falls back only where there is no bundle at all — under `swift test`, where every store is redirected
        // to a temporary directory anyway, so the value is never used for real data.
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.parla.app", isDirectory: true)
    }

    /// Move a previous install's library to the current root. Call ONCE, before anything reads a store.
    ///
    /// Only when the destination does not exist: an existing root is the live library and must never be merged
    /// into, because a merge of two partial libraries produces a history file that is neither. A rename within
    /// one volume is atomic, so a half-moved library is not a state this can produce.
    ///
    /// That guard is belt-and-braces rather than the only defence — `moveItem` refuses an existing destination
    /// on its own, which is why removing the guard does not turn the test red. Keep both: the explicit one says
    /// what is intended, and it avoids doing filesystem work to discover an answer we already have.
    ///
    /// Returns the folder name it moved from, if any — for tests and for the log.
    @discardableResult
    public static func migrateIfNeeded(support: URL? = nil, into destination: URL? = nil) -> String? {
        let fm = FileManager.default
        let target = destination ?? url
        guard !fm.fileExists(atPath: target.path) else { return nil }
        let base = support ?? target.deletingLastPathComponent()
        for name in legacyFolderNames {
            let old = base.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            // A FILE with that name is not a library; moving it would produce a "root" that cannot be written into.
            guard fm.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue else { continue }
            try? fm.createDirectory(at: base, withIntermediateDirectories: true)
            if (try? fm.moveItem(at: old, to: target)) != nil { return name }
        }
        return nil
    }
}
