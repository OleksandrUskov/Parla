import SwiftUI
import AVFoundation
import ParlaCore

/// The rich reading surface (iOS-port P1.4d) — a pinned player + Transcript/Digest picker on top, the scrolling
/// transcript below (tap-to-seek segments, or collapsible chapters for long audio, or the per-chapter digest).
/// Composed ENTIRELY from the SHARED ParlaCore views (`TransportBar`/`SegmentList`/`ChapterListView`/
/// `ChapterDigestView`) the Mac app also renders → true cross-platform parity. Chrome (background/title/toolbar)
/// is the caller's; this is the reading content. Mirrors the macOS `TranscriptCard` reading body 1:1.
struct TranscriptDetailView: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem
    @State private var player = PlaybackController()
    @State private var showDigest = false

    private var audioURL: URL? { AudioStore.playableURL(for: item) }
    private var hasChapterDigest: Bool { (item.chapterSummaries ?? []).contains { !$0.summary.isEmpty } }

    var body: some View {
        VStack(spacing: 12) {
            pinnedTop
            ScrollView {
                // Insights above, transcript/chapters/digest in the middle, Related below — the macOS
                // TranscriptCard reading stack, 1:1, via the same shared Core views (P1.4g).
                VStack(alignment: .leading, spacing: 12) {
                    InsightsView(item: item)
                    readingBody
                    RelatedNotesView()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 24)
            }
        }
        .padding(.horizontal)
        .task(id: item.id) {
            model.selection = item.id   // mark this the open note (audio-cache protection + Related bind to it)
            showDigest = false
            player.load(audioURL)       // AVAudioSession(.playback) is wired inside PlaybackController.load on iOS
            model.refreshRelatedNotes() // recompute the doc↔doc "Related" for the newly-opened note (best-effort)
        }
        // The container audio copy (keepAudio) lands AFTER the transcript is first shown, so audioURL goes
        // nil → real for the same item id (and .task doesn't re-fire on a same-id change). Reload when it
        // arrives so a just-imported note gets a working player. load() is idempotent (guard loadedURL != url).
        .onChange(of: audioURL) { _, url in player.load(url) }
        // Tear down when the detail leaves the screen (nav pop, or a fresh import auto-pushes over it):
        // PlaybackController
        // has no deinit — stop() invalidates the 0.1s ticker — and we release the audio session so playback
        // stops ducking other apps once the user navigates away.
        .onDisappear {
            player.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Fixed above the scroll: the player transport + (for a long note with summaries) the Transcript⇄Digest toggle.
    private var pinnedTop: some View {
        VStack(spacing: 10) {
            TransportBar(player: player, hasAudio: audioURL != nil)
            if hasChapterDigest {
                Picker("", selection: $showDigest) {
                    Text(L("view.transcript")).tag(false)
                    Text(L("view.digest")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
            }
        }
    }

    @ViewBuilder private var readingBody: some View {
        if showDigest, hasChapterDigest {
            ChapterDigestView(item: item)
        } else if model.showTimestamps, !item.isEdited, !item.segments.isEmpty {
            if AudioChunker.isLong(durationSec: item.durationSec) {
                ChapterListView(item: item, player: player, tappable: audioURL != nil)
            } else {
                SegmentList(segments: item.segments, player: player, tappable: audioURL != nil)
            }
        } else {
            Text(item.text)
                .font(.system(.body, design: .rounded))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
