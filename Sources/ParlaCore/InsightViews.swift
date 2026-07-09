import SwiftUI

// MARK: - Shared insight UI (iOS-port P1.4g)
//
// The AI-layer reading components — keyword tags + a collapsible summary + an action-items checklist, and the
// "Related notes" doc↔doc semantic footer — extracted VERBATIM from the macOS `TranscriptCard` (MainPane.swift)
// into ParlaCore as `public` SwiftUI, so both apps render the SAME views (true parity, zero duplication). They
// depend only on `AppModel` / `TranscriptItem` / `Brand` — all already in Core. Insights are best-effort: each
// block shows only when its toggle is on AND there's content, so the surface stays clean for short/plain notes
// and degrades to nothing on iOS where a field's backend isn't available (e.g. generative action-items).
// The whole view collapses to `EmptyView` when empty, so an insight-less note gets no phantom spacing in the
// parent stack — matching the macOS `@ViewBuilder` it replaced. (IOS_P1_4_UI §2.)

/// AI insight fields under the header: keyword tags + a collapsible summary + an action-items checklist.
public struct InsightsView: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem
    // Collapsed by default so it never crowds out the timestamped transcript; reset when the open note changes.
    @State private var summaryExpanded = false

    public init(item: TranscriptItem) { self.item = item }

    /// Any insight block would render → drives whether we emit a container at all (EmptyView otherwise, so a
    /// plain note adds no spacing in the parent stack).
    private var hasContent: Bool {
        (model.showKeywords && !(item.keywords?.isEmpty ?? true)) ||
        (model.showSummaries && !(item.summary?.isEmpty ?? true)) ||
        (model.showActions && !(item.actions?.isEmpty ?? true))
    }

    public var body: some View {
        if hasContent {
            VStack(alignment: .leading, spacing: 12) {
                keywordTags
                summaryBlock
                actionItems
            }
            .onChange(of: item.id) { _, _ in summaryExpanded = false }
        }
    }

    @ViewBuilder private var keywordTags: some View {
        if model.showKeywords, let keywords = item.keywords, !keywords.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "tag").font(.caption2).foregroundStyle(.secondary)
                ForEach(keywords, id: \.self) { keyword in
                    Text(keyword)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Brand.accent.opacity(0.15), in: Capsule())
                        .foregroundStyle(Brand.accent)
                }
                Spacer(minLength: 0)
            }
            .accessibilityLabel(Text(L("transcript.keywords")))
        }
    }

    // Collapsible so it never crowds out the timestamped transcript (which stays the primary content);
    // collapsed by default → click the header to reveal the TL;DR.
    @ViewBuilder private var summaryBlock: some View {
        if model.showSummaries, let summary = item.summary, !summary.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { summaryExpanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: summaryExpanded ? "chevron.down" : "chevron.right").font(.caption2)
                        Text(L("transcript.summary").uppercased()).font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if summaryExpanded {
                    Text(summary).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // Action items (generative tier only — FoundationModels). A tappable checklist; tap toggles done.
    @ViewBuilder private var actionItems: some View {
        if model.showActions, let actions = item.actions, !actions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "checklist").font(.caption2)
                    Text(L("transcript.actions").uppercased()).font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                ForEach(Array(actions.enumerated()), id: \.offset) { i, action in
                    Button { model.toggleAction(i, for: item.id) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: action.done ? "checkmark.circle.fill" : "circle")
                                .font(.callout)
                                .foregroundStyle(action.done ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.secondary))
                            Text(action.text)
                                .font(.callout)
                                .strikethrough(action.done)
                                .foregroundStyle(action.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Convey the done state to VoiceOver (not just the checkmark glyph): the row reads as a
                    // toggle and announces "selected" when done; the action text is the label.
                    .accessibilityLabel(Text(action.text))
                    .accessibilityAddTraits(action.done ? [.isToggle, .isSelected] : [.isToggle])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// "Related notes" — whole history notes close BY MEANING to the open one (doc↔doc semantic, computed in
/// `AppModel.refreshRelatedNotes`). A footer suggestion: shown only when something is genuinely related; each
/// row selects that note. This is where the on-device semantic layer actually helps — note↔note — since
/// word→note search isn't viable on the free model (that's the download tier; LOCAL_AI_LAYER.md §5).
public struct RelatedNotesView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        let related = model.relatedHistory
        if !related.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.caption2)
                    Text(L("transcript.related").uppercased()).font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                ForEach(related) { note in
                    // Clear any active search first: a related note is a topic match, not a query match, so it
                    // may be absent from filteredHistory — selectedItem (scoped to filteredHistory) couldn't
                    // resolve it and the tap would be a no-op. Clearing search makes navigation always land.
                    Button { model.searchQuery = ""; model.selection = note.id } label: {
                        HStack(spacing: 8) {
                            Text(model.showTitles ? note.displayTitle : note.sourceName)
                                .font(.callout).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(note.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
