import SwiftUI
import ParlaCore

/// The iPad-regular History shell (iOS-port P2.2b) — a two-column `NavigationSplitView`: a searchable, selectable
/// sidebar list (bound to `model.selection`, the same selection the macOS sidebar drives) and a detail column
/// that routes exactly like the compact `content` MINUS the list (failed/recording/busy → the selected
/// `TranscriptDetailView` → a placeholder). Reuses the shared HistoryShared leaf views; the compact iPhone/narrow
/// path stays HistoryListView (a NavigationStack), chosen by HistoryTab. Fully verifiable on the iPad simulator.
struct HistorySplitView: View {
    @Environment(AppModel.self) private var model
    let player: PlaybackController
    @State private var showImporter = false
    @State private var importing = false
    @State private var showClearConfirm = false
    @State private var shareItem: ShareItem?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            ZStack {
                AuroraBackground().ignoresSafeArea()
                sidebar
            }
            .dropDestination(for: URL.self) { urls, _ in importDropped(urls) }   // drag a file from Files → import
            .navigationTitle(L("history.title"))
            .toolbar { toolbarContent }
            .searchable(text: $model.searchQuery, prompt: L("history.search"))
            .onChange(of: model.searchQuery) { _, _ in model.onSearchQueryChanged() }
            .navigationSplitViewColumnWidth(min: 300, ideal: 340)
        } detail: {
            ZStack {
                AuroraBackground().ignoresSafeArea()
                detailColumn
            }
            .dropDestination(for: URL.self) { urls, _ in importDropped(urls) }   // drop onto the reading pane too
        }
        .navigationSplitViewStyle(.balanced)
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
        // Auto-select a freshly-produced transcript (the split analog of the compact auto-push): set the selection,
        // guarded on selection == nil so a background insert never yanks the user off a note they're reading.
        .onChange(of: model.history.count) { old, new in
            if new > old, model.selection == nil, let top = model.history.first { model.selection = top.id }
        }
    }

    // MARK: - Sidebar (selectable list bound to model.selection)

    @ViewBuilder private var sidebar: some View {
        @Bindable var model = model
        if model.history.isEmpty {
            HistoryEmptyView(onChoose: { showImporter = true })
        } else {
            List(selection: $model.selection) {
                ForEach(model.filteredHistory) { item in
                    HistoryRow(title: model.sidebarTitle(for: item), item: item)
                        .tag(item.id)
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
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Detail column (compact `content` precedence, minus the list, plus a placeholder)

    @ViewBuilder private var detailColumn: some View {
        if case .failed(let msg) = model.phase {
            HistoryFailedView(message: msg)
        } else if model.isRecordingDictation {
            HistoryRecordingView()
        } else if importing || model.isBusy {
            HistoryBusyView()
        } else if model.history.isEmpty {
            // No notes yet: show the full import hero HERE too, so "choose a file" is reachable in iPad portrait
            // where the sidebar (which also has it) is collapsed behind the toggle — otherwise a dead-end.
            HistoryEmptyView(onChoose: { showImporter = true })
        } else if let item = model.selectedItem {
            TranscriptDetailView(item: item, player: player)
                .navigationTitle(item.displayTitle)
                .navigationBarTitleDisplayMode(.inline)
        } else {
            placeholder   // has notes, none selected — the list (with import) is one sidebar-toggle away
        }
    }

    private var placeholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(Brand.gradient)
            Text(L("history.detail.placeholder"))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
    }

    // MARK: - Toolbar / import (shell-local state; the leaf views + import types are shared)

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showImporter = true } label: { Image(systemName: "plus.circle.fill") }
                .keyboardShortcut("i", modifiers: .command)   // ⌘I import — hardware keyboard on iPad
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

    private func shareHistory() {
        guard !model.history.isEmpty else { return }
        let md = exportText(model.history, content: model.exportContent)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parla-history.md")
        guard (try? Data(md.utf8).write(to: url)) != nil else { return }
        shareItem = ShareItem(url: url)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let picked) = result, !picked.isEmpty else { return }
        importing = true
        Task {
            let urls = await Task.detached(priority: .userInitiated) {
                ImportCoordinator.copyIntoContainer(picked)
            }.value
            importing = false
            if !urls.isEmpty { model.handleDrop(urls: urls) }
        }
    }

    /// Files-app drag-drop → the same copy-into-container-then-transcribe path as the file importer.
    /// (SwiftUI resolves `URL.self` to app-owned temp file URLs, valid past this callback.)
    private func importDropped(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        handleImport(.success(urls))
        return true
    }
}
