import SwiftUI

// MARK: - Shared reading UI
//
// The player transport + tap-to-seek segment list + long-audio chapters + digest — relocated VERBATIM from the
// macOS `MainPane.swift` into ParlaCore as `public` SwiftUI, so the macOS and iOS apps render the SAME views
// (true cross-platform parity, zero duplication). They depend only on `AppModel` / `PlaybackController` / pure
// Core helpers, all already here. `.help(_:)` is iOS-13.4+ so it needs no shim. (IOS_P1_4_UI §2.)

/// Transport: play/pause + scrubber + time. Degrades to a single note line if there's no audio
/// or the format isn't playable by the built-in player.
public struct TransportBar: View {
    let player: PlaybackController
    let hasAudio: Bool

    public init(player: PlaybackController, hasAudio: Bool) {
        self.player = player
        self.hasAudio = hasAudio
    }

    public var body: some View {
        if hasAudio && player.canPlay {
            HStack(spacing: 12) {
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3).foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Brand.gradient, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(player.isPlaying ? L("a11y.pause") : L("a11y.play")))
                Slider(value: Binding(get: { player.currentTime },
                                      set: { player.scrub(to: $0) }),
                       in: 0...max(player.duration, 0.01))
                    .tint(Brand.accent)
                Text("\(fmtTime(player.currentTime)) / \(fmtTime(player.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else if hasAudio {
            note(L("player.unsupported"))
        } else {
            note(L("player.noaudio"))
        }
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// List of segments with timestamps. Clicking a row (if there's audio) seeks the player.
/// The active segment is highlighted based on the current playback time.
public struct SegmentList: View {
    let segments: [Segment]
    let player: PlaybackController
    let tappable: Bool

    public init(segments: [Segment], player: PlaybackController, tappable: Bool) {
        self.segments = segments
        self.player = player
        self.tappable = tappable
    }

    private var activeIdx: Int? { activeSegmentIndex(segments, at: player.currentTime) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                if !seg.cleanText.isEmpty {
                    SegmentRow(seg: seg, active: i == activeIdx, tappable: tappable,
                               onSeek: { if tappable { player.seek(to: seg.start) } })
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
    }
}

public struct SegmentRow: View {
    let seg: Segment
    let active: Bool
    let tappable: Bool
    var onSeek: () -> Void

    public init(seg: Segment, active: Bool, tappable: Bool, onSeek: @escaping () -> Void = {}) {
        self.seg = seg
        self.active = active
        self.tappable = tappable
        self.onSeek = onSeek
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Timecode = the seek control: a click jumps the player. Selection is OFF here so clicking the digits
            // seeks (not selects); the transcript text beside it stays selectable/copyable.
            Button { onSeek() } label: {
                Text("[\(fmtTime(seg.start))]")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(active || tappable ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .disabled(!tappable)
            .textSelection(.disabled)
            Text(seg.cleanText)
                .font(.system(.body, design: .rounded))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(active ? AnyShapeStyle(Brand.gradient.opacity(0.18)) : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Chapter-grouped transcript for long recordings: collapsible ~2-min sections (first one expanded),
/// each a list of tap-to-seek segments. Derived from segments via `AudioChunker.chapters` — no state.
public struct ChapterListView: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem
    let player: PlaybackController
    let tappable: Bool

    public init(item: TranscriptItem, player: PlaybackController, tappable: Bool) {
        self.item = item
        self.player = player
        self.tappable = tappable
    }

    private var chapters: [Chapter] { AudioChunker.chapters(from: item.segments) }
    private var summaries: [ChapterSummary] { item.chapterSummaries ?? [] }
    /// Whether a generative backend can serve this note's language (RU/UK → MLX downloaded; EN → Apple Intelligence
    /// or the MLX fallback). Drives both the bulk button and the per-chapter regenerate buttons.
    private var canSummarize: Bool { model.ai.availability(forLanguage: item.language) == .ready }
    /// Match a chapter to its persisted summary by the stable start window (NOT positional index).
    private func summary(for chapter: Chapter) -> String? {
        summaries.first(where: { abs($0.startSec - chapter.startSec) < 0.5 })?.summary
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            chapterActions
            ForEach(chapters) { chapter in
                ChapterSection(chapter: chapter, summary: summary(for: chapter),
                               noteID: item.id, canSummarize: canSummarize,
                               player: player, tappable: tappable,
                               initiallyExpanded: chapter.index == 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
    }

    /// On-demand "Summarize chapters" — shown only when a generative backend can serve this language. Honest label:
    /// "Summarize" the first time (the summaries don't auto-exist), "Regenerate" once they do. A spinner runs while
    /// the BULK pass works; disabled while any chapter-summary work (bulk or single) is in flight for this note.
    @ViewBuilder private var chapterActions: some View {
        if canSummarize {
            let busy = model.summarizingChaptersIDs.contains(item.id)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Button { Task { await model.generateChapterSummaries(for: item.id) } } label: {
                    HStack(spacing: 5) {
                        if busy { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "sparkles").font(.caption2) }
                        Text(summaries.isEmpty ? L("chapter.summarize") : L("chapter.summarize.again"))
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Brand.accent.opacity(0.15), in: Capsule())
                    .foregroundStyle(Brand.accent)
                }
                .buttonStyle(.plain)
                .disabled(model.chapterWorkInFlight(for: item.id))
                .help(Text(L("chapter.summarize.help")))
            }
        }
    }
}

public struct ChapterSection: View {
    @Environment(AppModel.self) private var model
    let chapter: Chapter
    let summary: String?
    let noteID: UUID
    let canSummarize: Bool
    let player: PlaybackController
    let tappable: Bool
    @State private var expanded: Bool

    public init(chapter: Chapter, summary: String?, noteID: UUID, canSummarize: Bool,
                player: PlaybackController, tappable: Bool, initiallyExpanded: Bool) {
        self.chapter = chapter
        self.summary = summary
        self.noteID = noteID
        self.canSummarize = canSummarize
        self.player = player
        self.tappable = tappable
        _expanded = State(initialValue: initiallyExpanded)
    }

    private var ref: ChapterRef { ChapterRef(note: noteID, startSec: chapter.startSec) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — the WHOLE row toggles expand (not just the chevron). The regen button is a separate Button,
            // so it captures its own taps and doesn't toggle the row.
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 10)
                Text(Lf("chapter.title", chapter.index + 1)).font(.callout.weight(.semibold))
                Text(chapter.rangeLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if canSummarize { chapterRegenButton }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }

            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    // The chapter's AI summary — when generated — sits above its segments, marked with the
                    // insight glyph so it reads as a digest, not another transcript line.
                    if let summary, !summary.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Image(systemName: "sparkles").font(.caption2).foregroundStyle(Brand.accent)
                            Text(summary).font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }
                    ForEach(Array(chapter.segments.enumerated()), id: \.offset) { _, seg in
                        if !seg.cleanText.isEmpty {
                            SegmentRow(seg: seg, active: false, tappable: tappable,
                                       onSeek: { if tappable { player.seek(to: seg.start) } })
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 6)
            }
        }
        .tint(Brand.accent)
    }

    /// Per-chapter (re)generate — so one failed/poor chapter can be redone without re-running the whole recording.
    /// "sparkles" when the chapter has no summary yet (generate), "arrow.clockwise" once it does (regenerate); a
    /// spinner while THIS chapter works; disabled while any chapter-summary work for the note is in flight.
    @ViewBuilder private var chapterRegenButton: some View {
        let busy = model.summarizingChapters.contains(ref)
        Button { Task { await model.regenerateChapterSummary(for: noteID, startSec: chapter.startSec) } } label: {
            if busy { ProgressView().controlSize(.mini) }
            else { Image(systemName: summary == nil ? "sparkles" : "arrow.clockwise").font(.caption2) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Brand.accent)
        .disabled(model.chapterWorkInFlight(for: noteID))
        .help(Text(L(summary == nil ? "chapter.summarize.one" : "chapter.regenerate.one")))
    }
}

/// Read-only "Digest" of a long recording: every chapter's range + its AI summary, stacked for reading — no
/// segments, no expand. Shown via the Transcript⇄Digest toggle when chapter summaries exist (the navigable conspectus).
public struct ChapterDigestView: View {
    let item: TranscriptItem

    public init(item: TranscriptItem) {
        self.item = item
    }

    /// Chapters that actually have a summary, matched by the stable start window (NOT positional index).
    private var rows: [(chapter: Chapter, summary: String)] {
        let summaries = item.chapterSummaries ?? []
        return AudioChunker.chapters(from: item.segments).compactMap { ch in
            guard let s = summaries.first(where: { abs($0.startSec - ch.startSec) < 0.5 })?.summary,
                  !s.isEmpty else { return nil }
            return (ch, s)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(rows, id: \.chapter.id) { row in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(Lf("chapter.title", row.chapter.index + 1)).font(.callout.weight(.semibold))
                        Text(row.chapter.rangeLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text(row.summary).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
    }
}
