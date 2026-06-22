import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false
    @State private var showImporter = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(targeted ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.05))
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.4))

            VStack(spacing: 8) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 32))
                    .foregroundStyle(targeted ? Color.accentColor : .secondary)
                Text("Перетащи голосовое сюда")
                    .font(.headline)
                Button("или выбери файл…") { showImporter = true }
                    .buttonStyle(.link)
            }
        }
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            model.handleDrop(urls: urls)
            return true
        } isTargeted: { targeted = $0 }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio, .movie, .data],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.handleDrop(urls: urls) }
        }
        .disabled(model.isBusy)
        .opacity(model.isBusy ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.15), value: targeted)
    }
}
