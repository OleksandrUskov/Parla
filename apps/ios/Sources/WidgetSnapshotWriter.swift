import ParlaCore
import WidgetKit

/// Writes the Home-widget snapshot from the app's history. The `[TranscriptItem]→WidgetSnapshot`
/// mapping lives HERE (the app), not in the shared file — the widget can't link Core. Called on history change and
/// on launch; reloads the widget timelines after writing so the glance stays fresh.
enum WidgetSnapshotWriter {
    /// The most-recent notes to surface (medium widget shows up to 3; small shows the first).
    private static let maxNotes = 3

    static func write(from history: [TranscriptItem]) {
        let notes = history.prefix(maxNotes).map { item in
            WidgetSnapshot.Note(
                id: item.id,
                title: item.displayTitle,
                date: item.date,
                blurb: String(item.text.prefix(120)))
        }
        WidgetSnapshotStore.save(WidgetSnapshot(notes: Array(notes), totalCount: history.count))
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.kind)
    }
}
