import UIKit
import UniformTypeIdentifiers

/// Parla Share Extension — COPY-ONLY. A share extension is a separate, memory-limited process
/// that can't run WhisperKit, so it just copies the shared voice note(s) into the App Group inbox and completes;
/// the main app drains that inbox and transcribes on its next foreground (see `ShareInbox`). Deliberately lean:
/// it does NOT link ParlaCore — only Foundation/UIKit — so it stays well under the extension memory budget. The
/// group id + inbox name are duplicated from `ShareInbox` (a stable constant; keep the two in sync).
class ShareViewController: UIViewController {
    private let groupID = "group.com.parla.ios"   // must match ShareInbox.groupID
    private let inboxName = "inbox"                 // must match ShareInbox.inboxName
    /// In-progress copies carry this suffix so the app's drain skips them. Must match `ShareInbox.partSuffix`
    /// (the extension can't link ParlaCore — extension memory budget — so the constant is duplicated by necessity).
    static let partSuffix = ".part"

    override func viewDidLoad() {
        super.viewDidLoad()
        handleShare()
    }

    private func handleShare() {
        let attachments = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        guard !attachments.isEmpty, let inbox = inboxURL() else { return complete() }

        let group = DispatchGroup()
        for provider in attachments {
            // Load the item as its OWN declared type (registeredTypeIdentifiers is ordered most-specific-first)
            // rather than assuming public.data — more reliable across share sources (a Telegram .ogg vends its
            // audio type, not necessarily public.data) and it yields a file URL with the correct extension, which
            // the app routes on (.ogg → Opus). Falls back to public.data if the provider declares nothing.
            let typeID = provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
            group.enter()
            // The URL is only valid inside the closure, so copy it into the shared inbox immediately.
            provider.loadFileRepresentation(forTypeIdentifier: typeID) { url, _ in
                defer { group.leave() }
                guard let url else { return }
                // ATOMIC HANDOFF. The app drains this same directory on every foreground — it enumerates, copies
                // into its own container and DELETES the source. Copying straight to the final name meant the app
                // could pick a file up MID-COPY: it would move a truncated file and delete the user's only copy of
                // what they shared. So: copy to `<name>.part` (which the drain filter ignores), then `moveItem` —
                // a rename within one volume is atomic, so the final name appears only when the bytes are all there.
                let finalName = Self.uniqueName(for: url)
                let part = inbox.appendingPathComponent(finalName + Self.partSuffix)
                let dest = inbox.appendingPathComponent(finalName)
                do {
                    try FileManager.default.copyItem(at: url, to: part)
                    try FileManager.default.moveItem(at: part, to: dest)
                } catch {
                    try? FileManager.default.removeItem(at: part)   // never leave half a file behind
                }
            }
        }
        group.notify(queue: .main) { [weak self] in self?.complete() }
    }

    private func inboxURL() -> URL? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { return nil }
        let inbox = container.appendingPathComponent(inboxName, isDirectory: true)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    /// A collision-free filename that preserves the extension (the app routes by extension: .ogg → Opus, etc.).
    private static func uniqueName(for url: URL) -> String {
        let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let safeBase = base.isEmpty ? "voice" : base
        return "\(safeBase)-\(UUID().uuidString).\(ext)"
    }

    private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
