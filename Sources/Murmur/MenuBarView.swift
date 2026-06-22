import SwiftUI
import AppKit

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "waveform")
                Text("Murmur").fontWeight(.semibold)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
            }

            Divider()

            if model.history.isEmpty {
                Text("Пока нет расшифровок")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Недавние (клик — скопировать)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.history.prefix(6)) { item in
                    Button { model.copyItem(item) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.sourceName).lineLimit(1).font(.callout)
                            Text(item.text).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Открыть окно", systemImage: "macwindow").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            SettingsLink {
                Label("Настройки…", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Выйти", systemImage: "power").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 300)
    }
}
