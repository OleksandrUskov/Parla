import Foundation

/// One place for the rule every large, re-downloadable model tree must obey: **it does not belong in the user's
/// backup.** On iOS that is App Store 2.5 (weights inflating an iCloud backup is a rejection reason); on macOS the
/// same flag keeps multi-gigabyte weights out of Time Machine. Nothing is lost by excluding them — by definition
/// they can be fetched again.
///
/// This rule used to live in exactly one place (`TranscriptionEngine.prepareModelStorage`, WhisperKit only), so the
/// two model stores added later — the ~2.3 GB MLX/Qwen generative model and the MLX embedding model — were backed up
/// in full. Consolidated here so a NEW model store cannot silently forget it.
public enum ModelStorage {

    /// Create `url` if needed and mark that subtree excluded from backup. Idempotent.
    ///
    /// Best-effort by design: a failure must never block a download. The model still works; it is merely backed up,
    /// which is a storage cost, not a functional one. Returns whether the flag was actually set (test seam).
    @discardableResult
    public static func prepareExcludedFromBackup(_ url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do { try target.setResourceValues(values); return true } catch { return false }
    }

    /// Whether `url` currently carries the exclusion flag. Used by the tests that pin the invariant.
    public static func isExcludedFromBackup(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup ?? false
    }

    /// Move a model tree left behind at an older location, one repo OWNER at a time.
    ///
    /// Deliberately not `moveItem(at: legacy, to: current)` on the whole directory. The legacy base is HubApi's
    /// default (`~/Documents/huggingface`), which means it is shared ground: any other app built on
    /// swift-transformers downloads into the same place. Relocating the whole thing would silently take that
    /// app's models with it. So only the owners this app is known to populate are moved, and anything else is
    /// left exactly where it is. This repo has already had one recursive delete trust a directory it should not
    /// have (a chunk cleanup that took out the shared temp root); the same caution applies to moving.
    ///
    /// A rename within one volume is atomic, and both paths are under the user's home, so a half-moved model is
    /// not a state this can produce. An owner already present at the destination is skipped rather than merged —
    /// the destination is the live tree and must win.
    ///
    /// Returns the owners actually moved (for logging and tests). Best-effort throughout: a model that fails to
    /// move is simply re-downloaded, which is the same cost as never having had it.
    @discardableResult
    public static func migrateLegacyTree(from legacy: URL, to current: URL, owners: [String]) -> [String] {
        let fm = FileManager.default
        let legacyModels = legacy.appendingPathComponent("models", isDirectory: true)
        guard fm.fileExists(atPath: legacyModels.path) else { return [] }

        let currentModels = current.appendingPathComponent("models", isDirectory: true)
        var moved: [String] = []
        for owner in owners {
            let src = legacyModels.appendingPathComponent(owner, isDirectory: true)
            let dst = currentModels.appendingPathComponent(owner, isDirectory: true)
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
            try? fm.createDirectory(at: currentModels, withIntermediateDirectories: true)
            if (try? fm.moveItem(at: src, to: dst)) != nil { moved.append(owner) }
        }
        // Tidy up, but only what WE emptied: a leftover directory belonging to someone else keeps the tree alive.
        removeIfEmpty(legacyModels)
        removeIfEmpty(legacy)
        return moved
    }

    /// Remove a directory ONLY if it has nothing left in it. Anything at all — including another app's models or
    /// a stray `.DS_Store` — makes this a no-op, which is the safe way round.
    private static func removeIfEmpty(_ url: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path),
              contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
