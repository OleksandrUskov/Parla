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

            // Quick actions — no permissions needed. You can drag a file into the open popover below.
            Button { model.quickTranscribeFromClipboard() } label: {
                Label(L("menu.transcribe.clipboard"), systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy || model.downloadingModel != nil)

            Button { model.transcribeLast() } label: {
                Label(L("menu.repeat.last"), systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy || model.downloadingModel != nil)

            Divider()

            if model.history.isEmpty {
                Text(L("menu.empty")).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L("menu.recent")).font(.caption).foregroundStyle(.secondary)
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
                NSApp.activate()   // macOS 14: without ignoringOtherApps (deprecated)
            } label: {
                Label(L("menu.openwindow"), systemImage: "macwindow").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            SettingsLink {
                Label(L("menu.settings"), systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                NSApp.terminate(nil)
            } label: {
                Label(L("menu.quit"), systemImage: "power").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 300)
        .id(model.uiLanguage)   // re-resolve verbatim L() strings live on a UI-language switch
        // Dropping a file into the OPEN popover (macOS doesn't support dropping onto the closed icon — see blueprint).
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
