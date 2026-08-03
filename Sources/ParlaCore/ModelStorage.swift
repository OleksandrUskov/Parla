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
}
