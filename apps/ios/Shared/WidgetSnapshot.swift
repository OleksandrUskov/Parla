import Foundation

/// The data the Home-screen widget shows, written by the app into the App Group so the ParlaCore-free widget can
/// read it without linking Core (iOS-port P2.3c). Foundation-only. The `[TranscriptItem]→WidgetSnapshot` mapping
/// runs in the APP (`WidgetSnapshotWriter`), since the widget can't see Core types.
struct WidgetSnapshot: Codable {
    var notes: [Note]
    var totalCount: Int

    struct Note: Codable, Identifiable, Hashable {
        var id: UUID
        var title: String
        var date: Date
        var blurb: String   // ≤120 chars of the transcript
    }

    static let empty = WidgetSnapshot(notes: [], totalCount: 0)
}

/// App-Group-backed store for the widget snapshot. Nil-safe: if the container is unavailable (unsigned sim /
/// entitlement not provisioned) `save` is a no-op and `load` returns nil → the widget falls back to its empty
/// state. Mirrors ShareInbox's App-Group handling. Foundation-only (usable from BOTH the app and the widget).
enum WidgetSnapshotStore {
    static let groupID = "group.com.parla.ios"
    static let kind = "ParlaRecentNotes"           // WidgetKind — app reloads this; the widget declares it
    private static let fileName = "widget-snapshot.json"

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent(fileName)
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let url = fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return nil }
        return snap
    }
}
