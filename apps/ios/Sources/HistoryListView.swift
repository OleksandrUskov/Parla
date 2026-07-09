import SwiftUI
import UniformTypeIdentifiers
import ParlaCore

/// «История» — the COMPACT History shell (iOS-port P1.4e; iPad split is HistorySplitView, P2.2). A
/// `NavigationStack` + `List` over `model.filteredHistory` (the SAME lexical+lemma filter the macOS sidebar
/// renders) pushes each row to the shared `TranscriptDetailView`. Import stays in the toolbar (the P1.4b
/// copy-into-container flow); a finished transcription auto-pushes its result so the flow stays
/// one-shot — pick → progress → text, no extra tap. Row/state views + import types are shared (HistoryShared).
/// The `player` is injected from HistoryTab (above the compact↔regular swap) so playback survives an iPad resize.
struct HistoryListView: View {
    @Environment(AppModel.self) private var model
    let player: PlaybackController
    @State private var showImporter = false
    @State private var importing = false          // copying picks into the container (before handleDrop starts)
    @State private var showClearConfirm = false
    @State private var path: [TranscriptItem.ID] = []   // nav stack: the pushed transcript id(s)
    @State private var shareItem: ShareItem?            // whole-history backup export (P1.4h)

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
                          allowedContentTypes: HistoryImport.types,
                          allowsMultipleSelection: true,
                          onCompletion: handleImport)
            .confirmationDialog(L("history.clear.confirm.title"), isPresented: $showClearConfirm,
                                titleVisibility: .visible) {
                Button(L("history.clear.confirm.button"), role: .destructive) { model.clearHistory() }
                Button(L("common.cancel"), role: .cancel) {}
            } message: {
                Text(L("history.clear.confirm.message"))
            }
            .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
        }
        // Auto-open a freshly-produced transcript so the flow is one-shot (pick/record → progress → text, no extra
        // tap). Key on the history COUNT rising — the real "a new item was added" signal — NOT on a phase edge:
        // an empty/failed dictation returns .idle from .preparing without inserting anything (would push a STALE
        // item), and the default streaming dictation never leaves .idle at all (a phase edge would never fire).
        // Counting the insert handles import + both dictation paths and never fires on delete/clear (count drops).
        // `path.isEmpty` so a background insert never yanks the user out of a detail they're reading.
        .onChange(of: model.history.count) { old, new in
            if new > old, path.isEmpty, let top = model.history.first { path = [top.id] }
        }
    }

    // MARK: - Content states

    @ViewBuilder private var content: some View {
        if case .failed(let msg) = model.phase {
            HistoryFailedView(message: msg)
        } else if model.isRecordingDictation {
            HistoryRecordingView()
        } else if importing || model.isBusy {
            HistoryBusyView()
        } else if model.history.isEmpty {
            HistoryEmptyView(onChoose: { showImporter = true })
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
                TranscriptDetailView(item: item, player: player)   // sets model.selection = item.id in its .task
            }
            .navigationTitle(item.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
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
        ToolbarItem(placement: .topBarTrailing) {
            Button { model.toggleDictation() } label: { Image(systemName: "mic.fill") }
                .disabled(!model.canDictate)
                .accessibilityLabel(L("dictation.label"))
        }
        if !model.history.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button { shareHistory() } label: {
                        Label(L("history.export.help"), systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) { showClearConfirm = true } label: {
                        Label(L("history.clear.confirm.button"), systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    /// Whole-history backup → a single Markdown file (the honored 3-mode content) shared via the system sheet.
    private func shareHistory() {
        guard !model.history.isEmpty else { return }
        let md = exportText(model.history, content: model.exportContent)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parla-history.md")
        guard (try? Data(md.utf8).write(to: url)) != nil else { return }
        shareItem = ShareItem(url: url)
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
}
