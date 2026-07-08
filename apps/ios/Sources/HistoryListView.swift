import SwiftUI
import UniformTypeIdentifiers
import ParlaCore

/// «История» tab (iOS-port P1.4e) — the browsable, searchable transcript list that replaces P1.4b's inline
/// single-transcript home. A `NavigationStack` + `List` over `model.filteredHistory` (the SAME lexical+lemma
/// filter the macOS sidebar renders) pushes each row to the shared `TranscriptDetailView`. Import stays in the
/// toolbar (the P1.4b copy-into-container flow, unchanged); a finished transcription auto-pushes its result so
/// the flow stays one-shot — pick → progress → text, no extra tap. Delete = swipe;
/// Clear-all = toolbar. All state + filtering is pure Core, already unit-tested on macOS.
struct HistoryListView: View {
    @Environment(AppModel.self) private var model
    @State private var showImporter = false
    @State private var importing = false          // copying picks into the container (before handleDrop starts)
    @State private var showClearConfirm = false
    @State private var path: [TranscriptItem.ID] = []   // nav stack: the pushed transcript id(s)

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            ZStack {
                AuroraBackground().ignoresSafeArea()
                content
            }
            .navigationTitle(L("history.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .navigationDestination(for: TranscriptItem.ID.self, destination: detail)
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: Self.importTypes,
                          allowsMultipleSelection: true,
                          onCompletion: handleImport)
            .confirmationDialog(L("history.clear.confirm.title"), isPresented: $showClearConfirm,
                                titleVisibility: .visible) {
                Button(L("history.clear.confirm.button"), role: .destructive) { model.clearHistory() }
                Button(L("common.cancel"), role: .cancel) {}
            } message: {
                Text(L("history.clear.confirm.message"))
            }
        }
        // When a transcription finishes (phase returns to .idle after a run), open its result so the import flow
        // is pick → progress → text without an extra tap. Transcription is single-flight (isBusy blocks concurrent
        // jobs), so we're reliably on the list — not inside a detail — when this fires.
        .onChange(of: model.phase) { old, new in
            guard case .idle = new else { return }
            switch old {
            case .transcribing, .preparing:
                if let fresh = model.selectedItem { path = [fresh.id] }
            default: break
            }
        }
    }

    // MARK: - Content states

    @ViewBuilder private var content: some View {
        if case .failed(let msg) = model.phase {
            failedView(msg)
        } else if importing || model.isBusy {
            busyView
        } else if model.history.isEmpty {
            emptyState
        } else {
            listView
        }
    }

    /// The browsable list: the shared lexical+lemma `filteredHistory`, tap-to-push, swipe-to-delete, searchable.
    private var listView: some View {
        @Bindable var model = model
        return List {
            ForEach(model.filteredHistory) { item in
                NavigationLink(value: item.id) {
                    HistoryRow(title: model.sidebarTitle(for: item), item: item)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { model.delete(item) } label: {
                        Label(L("common.delete"), systemImage: "trash")
                    }
                }
            }
            if model.filteredHistory.isEmpty {   // an active search matched nothing
                Text(L("history.notfound"))
                    .foregroundStyle(.secondary).font(.callout)
                    .frame(maxWidth: .infinity).padding(.top, 24)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)   // let the Aurora show through the List
        .searchable(text: $model.searchQuery,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: L("history.search"))
        .onChange(of: model.searchQuery) { _, _ in model.onSearchQueryChanged() }
    }

    /// The pushed reading surface for a row — the shared Core `TranscriptDetailView` over Aurora chrome.
    /// Resolves the item by id (survives edits); if it was deleted out from under the push, bounce back.
    @ViewBuilder private func detail(for id: TranscriptItem.ID) -> some View {
        if let item = model.history.first(where: { $0.id == id }) {
            ZStack {
                AuroraBackground().ignoresSafeArea()
                TranscriptDetailView(item: item)
            }
            .navigationTitle(item.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .task { model.selection = id }   // keep Core selection in sync (audio-cache protection binds to it)
        } else {
            Color.clear.onAppear { if !path.isEmpty { path.removeLast() } }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showImporter = true } label: { Image(systemName: "plus.circle.fill") }
                .disabled(importing || model.isBusy)
                .accessibilityLabel(L("drop.choose"))
        }
        if !model.history.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button(role: .destructive) { showClearConfirm = true } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(L("history.clear.help"))
            }
        }
    }

    // MARK: - Busy / failed / empty (ported from the P1.4b home, unchanged)

    /// Busy = copying an import, downloading the model (determinate), the one-time ANE compile, or transcribing.
    /// A long recording chunks into an "N of M" pass (`BatchProgress`) — a multi-file batch too — so both get a
    /// determinate bar instead of a bare spinner (a 70-min file is ~35 chunks; the bar is real feedback).
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
            case .transcribing(let name, let batch), .preparing(let name, let batch):
                if let b = batch, b.total > 1 {
                    ProgressView(value: Double(b.done), total: Double(b.total))
                        .frame(maxWidth: 240).tint(Brand.accent)
                } else {
                    ProgressView().controlSize(.large)
                }
                Text(name).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            default:
                ProgressView().controlSize(.large)
                Text(busyLabel).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(32)
    }

    /// A failed run: message + in-place recovery (Try again / Dismiss) so the user is never stranded with
    /// their existing transcripts hidden behind the error.
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

    // MARK: - Import (P1.4b flow, verbatim)

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

/// One history row — mirrors the macOS `SidebarRow` content (title · 2-line snippet · date) as a floating card
/// over the Aurora list. Swipe replaces the macOS hover-delete; the NavigationLink chevron replaces selection.
private struct HistoryRow: View {
    let title: String
    let item: TranscriptItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium)).lineLimit(1)
            Text(item.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(item.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
        .padding(.vertical, 3)
    }
}
