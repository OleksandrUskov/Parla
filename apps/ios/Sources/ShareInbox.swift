import Foundation
import ParlaCore

/// The shared "inbox" bridging the Share Extension → the app (iOS-port P1.4j). The extension is a separate,
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
    static func pendingFiles(in dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { AppModel.audioExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Move any shared files into the app's own import container and hand them to the pipeline, clearing the
    /// inbox. The copy runs off-main (a big video would otherwise freeze foregrounding). No-op if the container
    /// is unavailable or empty. Call on app activation. Files land as a normal drop → queued if a job is running.
    @MainActor static func drain(into model: AppModel) {
        guard let inbox = inboxURL() else { return }
        let pending = pendingFiles(in: inbox)
        guard !pending.isEmpty else { return }
        Task {
            let containerURLs = await Task.detached(priority: .userInitiated) {
                let urls = ImportCoordinator.copyIntoContainer(pending)   // group files aren't scoped → a plain copy
                pending.forEach { try? FileManager.default.removeItem(at: $0) }   // clear the inbox regardless
                return urls
            }.value
            if !containerURLs.isEmpty { model.handleDrop(urls: containerURLs) }
        }
    }
}
