import SwiftUI
import UniformTypeIdentifiers
import ParlaCore

/// Home tab (iOS-port P1.4b) — the import + result surface that closes the on-device text loop: pick an audio
/// file (Telegram `.ogg` exercises the in-process Opusfile decoder) → copy into the container → `handleDrop`
/// → the transcript appears. The rich reading detail (pinned player, segments, chapters) + the history list
/// land in P1.4d/e; this shows the freshly-selected transcript inline so the pipeline is verifiable on device.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showImporter = false

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground().ignoresSafeArea()
                content
            }
            .navigationTitle(navTitle)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showImporter = true } label: { Image(systemName: "plus.circle.fill") }
                        .disabled(model.isBusy)
                        .accessibilityLabel(L("drop.choose"))
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: Self.importTypes,
                          allowsMultipleSelection: true,
                          onCompletion: handleImport)
        }
    }

    @ViewBuilder private var content: some View {
        if case .failed(let msg) = model.phase {
            status(icon: "exclamationmark.triangle.fill", tint: .orange, text: msg)
        } else if model.isBusy {
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(busyLabel).font(.callout).foregroundStyle(.secondary)
            }
            .padding(32)
        } else if let item = model.selectedItem {
            TranscriptDetailView(item: item)   // rich reading surface: pinned player + segments/chapters/digest
        } else {
            emptyState
        }
    }

    /// The nav title reflects the shown transcript (its title) or the tab name when idle/empty.
    private var navTitle: String {
        if case .failed = model.phase { return L("history.title") }
        if !model.isBusy, let item = model.selectedItem { return item.displayTitle }
        return L("history.title")
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(Brand.gradient)
            Text(L("empty.title")).font(.title2.weight(.semibold))
            Text(L("empty.subtitle"))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { showImporter = true } label: {
                Label(L("drop.choose"), systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.accent)
            .padding(.top, 4)
        }
        .padding(32)
    }

    private func status(icon: String, tint: Color, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(tint)
            Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private var busyLabel: String {
        switch model.phase {
        case .preparing(let n, _): return n
        case .transcribing(let n, _): return n
        default: return L("drop.working")
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let picked) = result, !picked.isEmpty else { return }
        let urls = ImportCoordinator.copyIntoContainer(picked)
        if !urls.isEmpty { model.handleDrop(urls: urls) }
    }

    /// Audio + video containers + Telegram Ogg/Opus (+ flac) by extension — a Telegram `.ogg` resolves to the
    /// same dynamic UTI this produces, so it's selectable without a bundled UTI declaration.
    static var importTypes: [UTType] {
        var t: [UTType] = [.audio, .movie, .mpeg4Audio, .mp3, .wav]
        for ext in ["ogg", "oga", "opus", "flac"] {
            if let u = UTType(filenameExtension: ext) { t.append(u) }
        }
        return t
    }
}
