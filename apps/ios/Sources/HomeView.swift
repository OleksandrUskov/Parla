import SwiftUI
import UniformTypeIdentifiers
import ParlaCore

/// Home tab (iOS-port P1.4b, hardened per the P1.4 review) — the import + result surface that closes the
/// on-device text loop: pick an audio file (Telegram `.ogg` exercises the in-process Opusfile decoder) → copy
/// into the container off the main thread → `handleDrop` → the transcript's rich detail appears. The history
/// list lands in P1.4e; this shows the freshly-selected transcript inline so the pipeline is verifiable on device.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var showImporter = false
    @State private var importing = false   // true while copying picks into the container (before handleDrop starts)

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
                        .disabled(importing || model.isBusy)
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
            failedView(msg)
        } else if importing || model.isBusy {
            busyView
        } else if let item = model.selectedItem {
            TranscriptDetailView(item: item)   // rich reading surface: pinned player + segments/chapters/digest
        } else {
            emptyState
        }
    }

    /// The nav title reflects the shown transcript (its title) or the tab name when idle/empty.
    private var navTitle: String {
        if case .failed = model.phase { return L("history.title") }
        if !importing, !model.isBusy, let item = model.selectedItem { return item.displayTitle }
        return L("history.title")
    }

    /// Busy = copying an import, downloading the model (determinate), the one-time ANE compile, or transcribing.
    @ViewBuilder private var busyView: some View {
        VStack(spacing: 14) {
            switch model.phase {
            case .downloadingModel(let p):
                ProgressView(value: p).frame(maxWidth: 240).tint(Brand.accent)
                Text("\(L("common.download"))… \(Int((p * 100).rounded()))%")
                    .font(.callout).foregroundStyle(.secondary)
            case .loadingModel:
                ProgressView().controlSize(.large)
                Text(L("status.loadingmodel.firstrun"))
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            default:
                ProgressView().controlSize(.large)
                Text(busyLabel).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(32)
    }

    /// A failed run: show the message + in-place recovery (Try again / Dismiss) so the user is never stranded
    /// on the error screen with their existing transcripts hidden.
    private func failedView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(.orange)
            Text(msg).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 12) {
                if model.canRetryLast {
                    Button(L("error.retry")) { model.retryLast() }
                        .buttonStyle(.borderedProminent).tint(Brand.accent)
                }
                Button(L("common.done")) { model.dismissError() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(32)
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

    private var busyLabel: String {
        switch model.phase {
        case .preparing(let n, _): return n
        case .transcribing(let n, _): return n
        default: return L("drop.working")
        }
    }

    /// Copy the picks into the container OFF the main thread (a large video would freeze the UI otherwise),
    /// showing a spinner via `importing`, then hand the container URLs to the pipeline on the main actor.
    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let picked) = result, !picked.isEmpty else { return }
        importing = true
        Task {
            let urls = await Task.detached(priority: .userInitiated) {
                ImportCoordinator.copyIntoContainer(picked)   // security scope is process-wide → safe off-main
            }.value
            importing = false
            if !urls.isEmpty { model.handleDrop(urls: urls) }
        }
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
