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
    @State private var shareItem: ShareItem?
    @State private var editing = false          // edit-in-place sheet (P2.1c)
    @State private var ttsPlayer = PlaybackController()   // read-aloud (TTS P2.1d) — separate from the source player
    @State private var synthesizingTTS = false            // brief spinner while the voice synthesizes the transcript

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { exportMenu }
            ToolbarItem(placement: .topBarTrailing) { actionsMenu }
            ToolbarItem(placement: .topBarTrailing) { readAloudButton }
        }
        .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
        .sheet(isPresented: $editing) {
            EditTranscriptSheet(initialTitle: item.title ?? "", initialText: item.text, onSave: applyEdit)
        }
        .task(id: item.id) {
            model.selection = item.id   // mark this the open note (audio-cache protection + Related bind to it)
            showDigest = false
            ttsPlayer.stop()            // switching notes stops any in-progress read-aloud
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
            ttsPlayer.stop()            // stop any read-aloud when the detail leaves the screen
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

    // MARK: - Reading actions (P2.1c) — Copy · Edit-in-place · Re-transcribe · Regenerate, mirroring the macOS
    // TranscriptCard `readActions` bar 1:1, folded into a single toolbar menu (per-chapter regenerate already
    // ships in the shared ChapterDigestView). Every backing API is already public in Core. Read-aloud → P2.1d.

    private var actionsMenu: some View {
        let regenerating = model.regeneratingIDs.contains(item.id)
        return Menu {
            Button { model.copyItem(item) } label: {
                Label(L("common.copy"), systemImage: "doc.on.doc")
            }
            if !model.isBusy {
                Button { editing = true } label: {
                    Label(L("transcript.edit.help"), systemImage: "pencil")
                }
            }
            // Re-transcribe on another model tier — a DEVICE-ONLY run (WhisperKit inference crashes on the sim).
            Menu {
                ForEach(model.modelTiers) { tier in
                    Button { model.retranscribe(item, with: tier.name) } label: {
                        if tier.name == item.model {
                            Label(Lf("model.menu.current", tier.title), systemImage: "checkmark")
                        } else if !model.isDownloaded(tier.name) {
                            Label(Lf("model.menu.download", tier.title), systemImage: "arrow.down.circle")
                        } else {
                            Text(tier.title)
                        }
                    }
                    .disabled(tier.name == item.model)   // same model — nothing to recompute
                }
            } label: {
                Label(L("transcript.retranscribe.help"), systemImage: "arrow.triangle.2.circlepath")
            }
            // Regenerate insights — all or one field; Tasks only when a generative backend can serve this note.
            if !model.isBusy {
                Menu {
                    Button(L("regenerate.all")) { Task { await model.regenerateInsights(for: item.id) } }
                    Section(L("regenerate.only")) {
                        Button(L("transcript.title")) { Task { await model.regenerateInsight(for: item.id, field: .title) } }
                        Button(L("transcript.summary")) { Task { await model.regenerateInsight(for: item.id, field: .summary) } }
                        Button(L("transcript.keywords")) { Task { await model.regenerateInsight(for: item.id, field: .keywords) } }
                        if model.ai.availability(forLanguage: item.language) == .ready {
                            Button(L("transcript.actions")) { Task { await model.regenerateInsight(for: item.id, field: .actions) } }
                        }
                    }
                } label: {
                    Label(L("transcript.regenerate"), systemImage: "sparkles")
                }
                .disabled(regenerating)
            }
        } label: {
            if regenerating { ProgressView().controlSize(.small) }
            else { Image(systemName: "ellipsis.circle") }
        }
        .accessibilityLabel(L("transcript.regenerate"))
    }

    /// Apply an edit-sheet result. Both `setTitle` and `saveEdit` invalidate the doc-vector/lemmas SYNCHRONOUSLY;
    /// the async best-effort re-embed is kicked HERE in the UI layer (never from a store mutation — a Task spawned
    /// inside the store could outlive a test; Core invariant, see the macOS `commitEdit`/`commitTitle`).
    private func applyEdit(title: String, text: String) {
        var changed = false
        if model.setTitle(title, for: item.id) { changed = true }
        if model.saveEdit(text, for: item.id) { changed = true }
        if changed { Task { await model.refreshSemanticIndex() } }
    }

    // MARK: - Read-aloud (TTS P2.1d) — mirrors the macOS TranscriptCard read-aloud button 1:1. SIM-VERIFIABLE
    // (SystemTTSService is AVSpeechSynthesizer, not gated); its own PlaybackController so it never fights the
    // note's source player. Best-effort + additive — off the isBusy lane, so it works even mid-transcription.

    private var readAloudButton: some View {
        Button { readAloud() } label: {
            if synthesizingTTS { ProgressView().controlSize(.small) }
            else { Image(systemName: ttsPlayer.isPlaying ? "stop.fill" : "speaker.wave.2.fill") }
        }
        .disabled(synthesizingTTS)
        .accessibilityLabel(L("transcript.readaloud"))
    }

    /// Speak the raw transcript aloud with a system voice. Best-effort — any failure silently no-ops, never
    /// disrupts the note. Toggles play↔stop; picks a voice for the note's language, falling back to any voice.
    private func readAloud() {
        if ttsPlayer.isPlaying { ttsPlayer.stop(); return }
        let speech = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !speech.isEmpty,
              let voice = model.tts.voices(forLanguage: item.language).first
                       ?? model.tts.voices(forLanguage: "").first else { return }
        player.stop()               // one audio at a time — pause the note's source player
        synthesizingTTS = true
        Task {
            defer { synthesizingTTS = false }
            do {
                let url = try await model.tts.synthesize(speech, voice: voice)
                ttsPlayer.load(url)
                ttsPlayer.togglePlay()
            } catch {
                // best-effort: a TTS failure never disrupts the transcript UI
            }
        }
    }

    // MARK: - Export (P1.4h) — mirrors the macOS TranscriptCard menu 1:1, delivering via the system share sheet
    // instead of NSSavePanel. Rendering is the pure Core layer (exportString / exportJSON).

    private var exportMenu: some View {
        Menu {
            // What goes in the file (remembered): transcript / +summary / summary-only — same 3-way as macOS.
            Picker(L("export.content"), selection: Binding(get: { model.exportContent },
                                                           set: { model.exportContent = $0 })) {
                ForEach(ExportContent.allCases) { Text($0.label).tag($0) }
            }
            Divider()
            ForEach(ExportFormat.allCases.filter { !$0.isSubtitle }) { fmt in
                // In "summary only" mode, hide the formats that need the transcript body (full JSON).
                if model.exportContent != .insightsOnly || fmt.supportsInsightsOnly {
                    Button(fmt.displayName) { share(fmt) }
                }
            }
            // Subtitles grouped + labelled (the video→subtitles win); they need the body, so hidden in summary-only.
            if model.exportContent != .insightsOnly {
                Section(L("export.subtitles")) {
                    ForEach(ExportFormat.allCases.filter { $0.isSubtitle }) { fmt in
                        Button(fmt.displayName) { share(fmt) }
                    }
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel(L("export.menu.help"))
    }

    /// Render the chosen format to a temp file (pure Core formatters) and present the system share sheet.
    private func share(_ fmt: ExportFormat) {
        let base = (item.sourceName as NSString).deletingPathExtension
        let name = base.isEmpty ? "transcript" : base
        let data: Data = fmt == .json
            ? ((try? exportJSON(item)) ?? Data())
            : Data(exportString(item, as: fmt, timestamps: model.showTimestamps, content: model.exportContent).utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).\(fmt.fileExtension)")
        guard (try? data.write(to: url)) != nil else { return }   // bad filename / write failure → no-op, never crash
        shareItem = ShareItem(url: url)
    }
}

/// Edit-in-place sheet (P2.1c). A modal `Form` — the iOS idiom the macOS inline editor maps to — editing the
/// title and the raw transcript text at once; the keyboard-avoidance comes free from Form. On Done it hands both
/// drafts back to the parent, which applies them via Core `setTitle`/`saveEdit` and kicks the re-embed. Editing
/// the text marks the note `isEdited` (segments collapse to plain text — same as the Mac).
private struct EditTranscriptSheet: View {
    let initialTitle: String
    let initialText: String
    var onSave: (_ title: String, _ text: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var text: String

    init(initialTitle: String, initialText: String, onSave: @escaping (String, String) -> Void) {
        self.initialTitle = initialTitle
        self.initialText = initialText
        self.onSave = onSave
        _title = State(initialValue: initialTitle)
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("transcript.title")) {
                    TextField(L("transcript.title"), text: $title)
                }
                Section(L("view.transcript")) {
                    TextEditor(text: $text)
                        .frame(minHeight: 240)
                        .font(.system(.body, design: .rounded))
                }
            }
            .navigationTitle(L("transcript.edit.help"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common.done")) { onSave(title, text); dismiss() }
                }
            }
        }
    }
}
