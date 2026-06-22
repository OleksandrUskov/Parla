import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false
    @State private var showImporter = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 22).fill(Brand.gradient.opacity(targeted ? 0.22 : 0))
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(Brand.gradient.opacity(targeted ? 0.95 : 0.4),
                              style: StrokeStyle(lineWidth: 2, dash: [9, 7]))

            VStack(spacing: 10) {
                Image(systemName: model.isBusy ? "waveform" : "waveform.badge.plus")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Brand.gradient)
                    .symbolEffect(.pulse, isActive: model.isBusy || targeted)
                Text(model.isBusy ? "Работаю…" : "Перетащи голосовое сюда")
                    .font(.system(.headline, design: .rounded))
                if !model.isBusy {
                    Button("или выбери файл…") { showImporter = true }
                        .buttonStyle(.plain)
                        .font(.subheadline)
                        .foregroundStyle(Brand.accent)
                }
            }
        }
        .scaleEffect(targeted ? 1.012 : 1)
        .shadow(color: targeted ? Brand.accent.opacity(0.45) : .clear, radius: 18, y: 6)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = await Self.loadFileURL(provider) { urls.append(url) }
                }
                if urls.isEmpty {
                    model.phase = .failed("Не смог получить файл из перетаскивания")
                } else {
                    model.handleDrop(urls: urls)
                }
            }
            return true
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio, .movie, .data],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.handleDrop(urls: urls) }
        }
        .animation(.spring(duration: 0.25), value: targeted)
        .animation(.easeInOut(duration: 0.2), value: model.isBusy)
    }

    /// Надёжно достаёт файловый URL из NSItemProvider (Finder/любой источник).
    nonisolated static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    cont.resume(returning: url)
                }
            } else {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data else { cont.resume(returning: nil); return }
                    if let s = String(data: data, encoding: .utf8), let url = URL(string: s) {
                        cont.resume(returning: url)
                    } else {
                        cont.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                    }
                }
            }
        }
    }
}
