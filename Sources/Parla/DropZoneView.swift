import SwiftUI
import ParlaCore
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

            VStack(spacing: 9) {
                // The status icon. While recording it's a tappable red mic → STOP, so you end the recording
                // right where you started it (no hunting for the separate Stop button).
                if model.isRecordingDictation {
                    Button { model.stopAndTranscribeDictation() } label: {
                        Image(systemName: "mic.circle.fill")
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse, isActive: true)
                    }
                    .buttonStyle(.plain)
                    .help(Text(L("dictation.stop")))
                } else {
                    Image(systemName: dropIcon)
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(Brand.gradient)
                        .symbolEffect(.pulse, isActive: model.isBusy || targeted)
                }
                Text(dropTitle)
                    .font(.system(.headline, design: .rounded))
                if model.isRecordingDictation {
                    Text(L("drop.tap.stop")).font(.caption2).foregroundStyle(.secondary)
                } else if !model.isBusy {
                    Button(L("drop.choose")) { showImporter = true }
                        .buttonStyle(.plain)
                        .font(.subheadline)
                        .foregroundStyle(Brand.accent)

                    // Dictate with the mic — the visible, discoverable entry point (the hotkey is opt-in).
                    Rectangle().fill(.secondary.opacity(0.25)).frame(width: 64, height: 1).padding(.vertical, 1)
                    Button { model.toggleDictation() } label: {
                        Label(L("drop.dictate"), systemImage: "mic.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 7)
                            .background(Brand.gradient, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canDictate)
                    .help(Text(L("drop.dictate.help")))
                    Text(L("drop.dictate.hint")).font(.caption2).foregroundStyle(.secondary)
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
                    model.phase = .failed(L("error.drop.failed"))
                } else {
                    model.handleDrop(urls: urls)
                }
            }
            return true
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio, .movie, .folder, .data],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { model.handleDrop(urls: urls) }
        }
        .animation(.spring(duration: 0.25), value: targeted)
        .animation(.easeInOut(duration: 0.2), value: model.isBusy)
    }

    private var dropIcon: String {
        if model.isRecordingDictation { return "mic.circle.fill" }
        return model.isBusy ? "waveform" : "waveform.badge.plus"
    }
    private var dropTitle: String {
        if model.isRecordingDictation { return L("drop.listening") }
        return model.isBusy ? L("drop.working") : L("drop.prompt")
    }

    /// Reliably extracts a file URL from an NSItemProvider (Finder/any source). `@MainActor` keeps the
    /// non-Sendable provider in the drop handler's actor region — handing it to a nonisolated context is a
    /// cross-isolation send that Swift 6.3's region isolation flags as a data-race risk. The loadObject /
    /// loadDataRepresentation kickoffs are non-blocking, so running them on the main actor costs nothing.
    @MainActor static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
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
