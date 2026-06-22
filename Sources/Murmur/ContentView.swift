import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.history) { item in
                    HistoryRow(item: item)
                        .tag(item.id as TranscriptItem.ID?)
                }
                .onDelete(perform: model.deleteHistory)
            }
            .navigationTitle("История")
            .overlay {
                if model.history.isEmpty {
                    ContentUnavailableView(
                        "Пусто",
                        systemImage: "tray",
                        description: Text("Перетащи голосовое, чтобы начать")
                    )
                }
            }
            .frame(minWidth: 240)
        } detail: {
            DetailPane()
                .frame(minWidth: 480)
        }
    }
}

struct HistoryRow: View {
    let item: TranscriptItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.sourceName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text(item.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(item.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
