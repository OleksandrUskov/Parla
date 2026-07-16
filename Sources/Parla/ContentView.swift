import SwiftUI
import ParlaCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    private let sidebarWidth: CGFloat = 268
    // Fixed reserve for the traffic-light strip. We deliberately DON'T rely on the window's title-bar
    // safe-area inset: SwiftUI resolves it asynchronously after the window attaches (~1s), so the content
    // visibly JUMPS once the provisional inset is swapped for the real one — and that inset is 0 in
    // fullscreen, where the hover-revealed title bar then overlaps the header. Reserving a constant strip
    // ourselves (and ignoring the system top inset) makes the top margin deterministic from the first
    // frame: no jump, no overlap, identical in windowed and fullscreen. 28pt = standard title-bar height.
    private let titleBarReserve: CGFloat = 28

    var body: some View {
        ZStack {
            // Aurora + frosted left rail composited into ONE full-window background layer. CRUCIAL: the frost is
            // an overlay INSIDE the (full-window, bleeding) AuroraBackground — NOT a separate column-width
            // `.ignoresSafeArea()` sibling. A column-shaped bleeding sibling sitting in the sidebar's column
            // collapses THAT column's title-bar safe-area inset (size-dependent, with a ~1s re-layout jump that
            // slides the «История» header up toward the traffic lights); a full-window bleeding background does
            // not — MainPane sits over the same AuroraBackground and never jumps. By painting the frost as a
            // full-window overlay, the rail still bleeds behind the title bar, but as a LAYOUT sibling it's
            // full-window (like aurora) → the sidebar CONTENT gets the same reliable inset as MainPane: no jump,
            // no overlap, consistent across window sizes and correct (inset 0) in fullscreen.
            AuroraBackground()
                .overlay(alignment: .leading) {
                    Rectangle().fill(.ultraThinMaterial)
                        .frame(width: sidebarWidth)
                        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.08)).frame(width: 1) }
                }
            HStack(spacing: 0) {
                SidebarView().frame(width: sidebarWidth)
                MainPane()
            }
            .padding(.top, titleBarReserve)              // reserve the traffic-light strip ourselves…
            .ignoresSafeArea(.container, edges: .top)     // …and don't depend on the title-bar safe-area inset
        }
        .frame(minWidth: 860, minHeight: 580)
        // Rebuild the tree on a UI-language switch so the verbatim L() strings re-resolve live.
        // (Text(L("key")) is verbatim and doesn't depend on environment(\.locale), so .id forces it;
        // model-held state — history/selection/search — survives, only transient @State resets.)
        .id(model.uiLanguage)
        // Handoff: receive a "view transcript" continuation from another device (iOS) → open the note.
        // Drains through pendingOpen (the same channel iOS uses), incl. on .task for a cold-launch continuation.
        .onContinueUserActivity(AppModel.viewTranscriptActivityType) { model.continueViewTranscript($0.userInfo) }
        .onChange(of: model.pendingOpen) { _, _ in drainPendingOpen() }
        .task { drainPendingOpen() }
    }

    /// Consume a Handoff/deep-link `pendingOpen` → select the note if it's on this Mac (consume regardless so a
    /// stale id can't stick).
    private func drainPendingOpen() {
        guard let id = model.pendingOpen else { return }
        model.pendingOpen = nil
        guard model.history.contains(where: { $0.id == id }) else { return }
        // Clear any active search first — selectedItem is scoped to filteredHistory, so a note filtered out by the
        // query would otherwise show the wrong record or nothing (same fix the Related nav uses).
        model.searchQuery = ""
        model.selection = id
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var showClearConfirm = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(L("history.title"))
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                if !model.history.isEmpty {
                    Button { model.exportHistory() } label: {
                        Image(systemName: "square.and.arrow.up").font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(Text(L("history.export.help")))
                    .accessibilityLabel(Text(L("history.export.help")))
                    Button { showClearConfirm = true } label: {
                        Image(systemName: "trash").font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(Text(L("history.clear.help")))
                    .accessibilityLabel(Text(L("history.clear.help")))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 8)

            if !model.history.isEmpty {
                TextField(L("history.search"), text: $model.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .onChange(of: model.searchQuery) { _, _ in model.onSearchQueryChanged() }
            }

            if model.history.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "tray").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text(L("history.empty")).foregroundStyle(.secondary).font(.callout)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.filteredHistory) { item in row(item) }
                        if model.filteredHistory.isEmpty {
                            Text(L("history.notfound")).foregroundStyle(.secondary).font(.callout)
                                .frame(maxWidth: .infinity).padding(.top, 24)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                }
            }
        }
        // Pure content view (transparent) — the frosted rail + divider live in ContentView as a separate
        // bleeding layer. Mirrors MainPane: no safe-area-ignoring background on the content path, so the
        // «История» header always sits below the title bar in windowed mode, like the main pane already does.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .confirmationDialog(L("history.clear.confirm.title"), isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button(L("history.clear.confirm.button"), role: .destructive) { model.clearHistory() }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("history.clear.confirm.message"))
        }
    }

    @ViewBuilder private func row(_ item: TranscriptItem) -> some View {
        SidebarRow(item: item, title: model.sidebarTitle(for: item), selected: model.selection == item.id,
                   onDelete: { model.delete(item) })
            .onTapGesture { model.selection = item.id }
            .contextMenu {
                Button(L("common.copy")) { model.copyItem(item) }
                Button(L("common.delete"), role: .destructive) { model.delete(item) }
            }
    }
}

struct SidebarRow: View {
    let item: TranscriptItem
    let title: String
    let selected: Bool
    var onDelete: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.weight(.medium)).lineLimit(1)
            Text(item.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Text(item.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            selected ? AnyShapeStyle(Brand.gradient.opacity(0.28)) : AnyShapeStyle(Color.white.opacity(0.05)),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Brand.accent.opacity(0.7) : Color.clear, lineWidth: 1)
        )
        // Visible per-note delete on hover (the right-click menu still works too).
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.caption2)
                        .padding(5).background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(Text(L("history.delete.help")))
                .accessibilityLabel(Text(L("history.delete.help")))
                .padding(6)
            }
        }
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
    }
}
