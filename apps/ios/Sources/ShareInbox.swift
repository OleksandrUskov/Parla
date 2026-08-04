import Foundation
import ParlaCore

/// The shared "inbox" bridging the Share Extension → the app. The extension is a separate,
/// memory-limited process that can't run WhisperKit, so it only COPIES incoming voice notes into the App Group
/// container; the app drains that inbox on foreground, moves each file into its own import container, and
/// transcribes — the copy-only handoff. All the App-Group I/O lives here; `pendingFiles` is pure so it's
/// unit-testable with an injected directory (the real container needs the provisioned entitlement → device-only).
enum ShareInbox {
    static let groupID = "group.com.parla.ios"
    static let inboxName = "inbox"

    /// The App Group container, or nil when the entitlement isn't provisioned (e.g. an unsigned sim build) —
    /// callers treat nil as "no inbox" and no-op, so the app never depends on it being present.
    static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    /// The inbox directory inside the container (created on demand), or nil if there's no container.
    static func inboxURL() -> URL? {
        guard let container = containerURL() else { return nil }
        let inbox = container.appendingPathComponent(inboxName, isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    /// Audio/video files waiting in an inbox directory — PURE, so a test injects a temp dir instead of the
    /// (entitlement-gated) real container. Filters to the formats the pipeline handles; hidden files skipped;
    /// stable order.
    /// Suffix the Share Extension gives an in-progress copy; it renames to the final name only once the bytes are
    /// all written. Must match `ShareViewController.partSuffix`.
    static let partSuffix = ".part"

    static func pendingFiles(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items
            // NEVER pick up an in-flight copy: the extension writes `<name>.part` and atomically renames when the
            // copy completes. Without this the app could move a TRUNCATED file into its container and then delete
            // the source — losing the user's only copy of what they shared. (`isTranscribable` would reject `.part`
            // by extension anyway; this is explicit so the invariant is impossible to break by accident.)
            .filter { !$0.lastPathComponent.hasSuffix(partSuffix) }
            // Extension OR Ogg content: the Share Extension can't sniff (it doesn't link ParlaCore), so an
            // extension-less shared voice note lands here as `.dat` — without this it would sit in the inbox forever.
            .filter { AppModel.isTranscribable($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Sweep `.part` files abandoned by a crashed/killed share (older than a day — never touch one that could
    /// still be in flight). Cheap, best-effort, keeps the shared container from accumulating dead bytes.
    static func sweepStaleParts(in dir: URL, olderThan age: TimeInterval = 86_400, now: Date = Date()) {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        for u in items where u.lastPathComponent.hasSuffix(partSuffix) {
            let mtime = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mtime, now.timeIntervalSince(mtime) > age { try? FileManager.default.removeItem(at: u) }
        }
    }

    /// Which inbox sources are safe to delete after a copy pass: ONLY those `copyIntoContainer` actually produced a
    /// container copy for. copyIntoContainer is best-effort per file and an inbox file is the user's ONLY copy of a
    /// shared note, so a file it couldn't copy must be KEPT to retry on the next foreground — deleting "regardless"
    /// loses it silently. Inbox filenames are unique (one directory), so matching by lastPathComponent is exact.
    /// PURE (no I/O) so the data-loss guard is unit-tested.
    static func toRemove(pending: [URL], containerURLs: [URL]) -> [URL] {
        let copied = Set(containerURLs.map { $0.lastPathComponent })
        return pending.filter { copied.contains($0.lastPathComponent) }
    }

    /// Single-flight guard: `drain` is invoked from BOTH the cold-launch `.task` AND every `scenePhase == .active`
    /// change, which can fire together (or back-to-back on a fast background→foreground). Without this, two drains
    /// read the same inbox files before either clears them → the SAME voice note imports + transcribes twice. The
    /// guard is set synchronously on the main actor (no await before it) so only one drain can ever claim the files.
    @MainActor private static var isDraining = false

    /// Move any shared files into the app's own import container and hand them to the pipeline, clearing the
    /// inbox. The copy runs off-main (a big video would otherwise freeze foregrounding). No-op if the container
    /// is unavailable, empty, or a drain is already in flight. Files land as a normal drop → queued if busy.
    @MainActor static func drain(into model: AppModel) {
        guard !isDraining, let inbox = inboxURL() else { return }
        sweepStaleParts(in: inbox)                 // clear leftovers from a crashed share (never an in-flight one)
        let pending = pendingFiles(in: inbox)
        guard !pending.isEmpty else { return }
        isDraining = true
        Task {
            defer { isDraining = false }
            let containerURLs = await Task.detached(priority: .userInitiated) {
                let urls = ImportCoordinator.copyIntoContainer(pending)   // group files aren't scoped → a plain copy
                // Remove ONLY the inbox files we actually copied (see toRemove below): an inbox file is the user's
                // ONLY copy of what they shared, so a copy failure must not delete it.
                for src in toRemove(pending: pending, containerURLs: urls) {
                    try? FileManager.default.removeItem(at: src)
                }
                return urls
            }.value
            if !containerURLs.isEmpty { model.handleDrop(urls: containerURLs) }
        }
    }
}
