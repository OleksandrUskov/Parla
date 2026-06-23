import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(Brand.gradient)
                Text(Brand.name).font(.system(.headline, design: .rounded)).foregroundStyle(Brand.gradient)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
            }

            Divider()

            // Быстрые действия — без разрешений. Перетащить файл можно в открытый поповер ниже.
            Button { model.quickTranscribeFromClipboard() } label: {
                Label("Распознать из буфера", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy || model.downloadingModel != nil)

            Button { model.transcribeLast() } label: {
                Label("Повторить последний файл", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy || model.downloadingModel != nil)

            Divider()

            if model.history.isEmpty {
                Text("Пока нет расшифровок").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Недавние (клик — скопировать)").font(.caption).foregroundStyle(.secondary)
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
                NSApp.activate()   // macOS 14: без ignoringOtherApps (deprecated)
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
        // Дроп файла в ОТКРЫТЫЙ поповер (дроп на закрытую иконку macOS не поддерживает — см. блупринт).
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for p in providers { if let u = await DropZoneView.loadFileURL(p) { urls.append(u) } }
                if !urls.isEmpty { model.handleDrop(urls: urls) }
            }
            return true
        }
    }
}
