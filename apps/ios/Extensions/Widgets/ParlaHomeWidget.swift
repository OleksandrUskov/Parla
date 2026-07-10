import WidgetKit
import SwiftUI

/// Home-screen widget (iOS-port P2.3c): a glance at the latest transcripts, read from the App-Group snapshot the
/// app writes (ParlaCore-free). Small = the latest note; Medium = up to three, each deep-linking to its note via
/// `parla://note?id=`. Empty state when there's no snapshot (fresh install, or the unsigned-sim App Group is nil).
struct ParlaHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshotStore.kind, provider: RecentNotesProvider()) { entry in
            RecentNotesView(entry: entry)
                .containerBackground(for: .widget) { WidgetBrand.background }
        }
        .configurationDisplayName("Parla — Recent")
        .description("Your latest transcripts at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct RecentNotesEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct RecentNotesProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentNotesEntry {
        RecentNotesEntry(date: Date(), snapshot: .sample)
    }
    func getSnapshot(in context: Context, completion: @escaping (RecentNotesEntry) -> Void) {
        // Gallery preview: real data if present, else a representative sample so the widget looks alive.
        completion(RecentNotesEntry(date: Date(), snapshot: WidgetSnapshotStore.load() ?? .sample))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentNotesEntry>) -> Void) {
        // Placed widget: the real snapshot or the honest empty state (the app reloads us on every history change).
        let snap = WidgetSnapshotStore.load() ?? .empty
        completion(Timeline(entries: [RecentNotesEntry(date: Date(), snapshot: snap)], policy: .never))
    }
}

struct RecentNotesView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RecentNotesEntry

    var body: some View {
        if let first = entry.snapshot.notes.first {
            if family == .systemSmall {
                smallView(first)
            } else {
                mediumView(entry.snapshot)
            }
        } else {
            emptyView
        }
    }

    // MARK: Small — the latest note

    private func smallView(_ note: WidgetSnapshot.Note) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "waveform").font(.title3).foregroundStyle(WidgetBrand.accent)
            Text(note.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            Text(note.blurb).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            Spacer(minLength: 0)
            Text(note.date, format: .dateTime.month().day().hour().minute())
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "parla://note?id=\(note.id.uuidString)"))
    }

    // MARK: Medium — up to three notes, each a deep-link

    private func mediumView(_ snap: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(WidgetBrand.accent)
                Text("Parla").font(.caption.weight(.bold))
                Spacer()
                Text("\(snap.totalCount)").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(snap.notes.prefix(3)) { note in
                Link(destination: URL(string: "parla://note?id=\(note.id.uuidString)")!) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(note.title).font(.caption.weight(.medium)).lineLimit(1)
                        Text(note.blurb).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var emptyView: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform").font(.title2).foregroundStyle(WidgetBrand.gradient)
            Text("No transcripts yet").font(.caption.weight(.medium))
            Text("Share a voice message to Parla").font(.caption2).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(URL(string: "parla://show"))
    }
}

extension WidgetSnapshot {
    /// Representative gallery-preview data (English — the widget can't reach the app's `L()`).
    static let sample = WidgetSnapshot(
        notes: [
            .init(id: UUID(), title: "Voice message", date: Date(),
                  blurb: "Hey, just confirming tomorrow at 3 — bring the notes and we'll finalize the plan."),
            .init(id: UUID(), title: "Meeting recap", date: Date().addingTimeInterval(-3600),
                  blurb: "We agreed to ship the iOS build first, then circle back on the widget polish."),
            .init(id: UUID(), title: "Idea", date: Date().addingTimeInterval(-7200),
                  blurb: "What if the summary could group action items by person automatically?"),
        ],
        totalCount: 12)
}
