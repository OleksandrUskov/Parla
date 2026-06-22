import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            AuroraBackground()
            HStack(spacing: 0) {
                SidebarView().frame(width: 268)
                MainPane()
            }
        }
        .frame(minWidth: 860, minHeight: 580)
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("История")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 10)

            if model.history.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("Пока пусто").foregroundStyle(.secondary).font(.callout)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.history) { item in
                            SidebarRow(item: item, selected: model.selection == item.id)
                                .onTapGesture { model.selection = item.id }
                                .contextMenu {
                                    Button("Скопировать") { model.copyItem(item) }
                                    Button("Удалить", role: .destructive) { model.delete(item) }
                                }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
        }
    }
}

struct SidebarRow: View {
    let item: TranscriptItem
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.sourceName).font(.callout.weight(.medium)).lineLimit(1)
            Text(item.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(item.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            selected ? AnyShapeStyle(Brand.gradient.opacity(0.28)) : AnyShapeStyle(Color.white.opacity(0.05)),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Brand.accent.opacity(0.7) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
