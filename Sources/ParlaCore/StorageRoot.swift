import Foundation

/// The one directory everything this app owns lives under, and the reason it is named after the bundle
/// identifier rather than after the app.
///
/// When a previously-unsandboxed macOS app becomes sandboxed — which the Mac App Store requires — the system
/// migrates its existing data into the new container on first launch, and it finds that data **by bundle
/// identifier**: `Application Support/<bundle-id>`, `Caches/<bundle-id>`, `Preferences/<bundle-id>.plist`.
/// Our store directory was named `Parla`, which matches nothing. A sandboxed build would therefore start on an
/// empty container while every file sat untouched on disk, invisible — and, because the preferences plist IS
/// bundle-ID-named and does migrate, the app would arrive *configured*: remembering a watched folder it cannot
/// watch and a last file it cannot replay. After that build ships there is no recovery from inside the app,
/// since a sandboxed process cannot read the old location at all.
///
/// Being honest about the uncertainty: the migration's exact matching rules are Apple's, not ours, and this
/// change is worth making even if it turns out the system would not have migrated anyway. Naming a store
/// directory after the bundle identifier is the convention regardless, it costs one rename, and it is the only
/// arrangement in which the automatic path CAN work. The in-app import fallback stays on the plan either way.
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
