import SwiftUI
import ParlaCore

struct MainPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Two reading layouts, toggled by `pinnedPlayerLayout` (instant, code-free rollback):
        // • PINNED — the chrome + card header + audio player stay FIXED, only the transcript scrolls (its own
        //   ScrollView filling the card height). One meaningful scroll axis (the transcript), player always visible.
        // • CLASSIC — the whole right pane is ONE ScrollView; everything flows and a long transcript extends the
        //   page (no nested ScrollView → no inner/outer conflict, nothing collapses to zero). Also used when no note.
        if model.pinnedPlayerLayout, let item = model.selectedItem {
            VStack(spacing: 18) {
                BrandHeader()
                DropZoneView().frame(height: 210)
                StatusBar()
                TranscriptCard(item: item, pinned: true)
                    .frame(maxHeight: .infinity)   // fill the remaining height so the transcript scroll is meaningful
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollView {
                VStack(spacing: 18) {
                    BrandHeader()
                    DropZoneView().frame(height: 210)
                    StatusBar()
                    if let item = model.selectedItem {
                        TranscriptCard(item: item)
                    } else {
                        EmptyState()
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }
}

struct BrandHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Brand.gradient)
            Text(Brand.name)
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .foregroundStyle(Brand.gradient)
            if model.translateToEnglish {
                Text("→ EN")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Brand.accent.opacity(0.25), in: Capsule())
                    .foregroundStyle(Brand.accent)
                    .help(Text(L("header.translate.help")))
            }
            if model.watchEnabled {
                HStack(spacing: 4) {
                    Image(systemName: "eye.fill").font(.caption2)
                    if model.watchQueueCount > 0 {
                        Text("\(model.watchQueueCount)").font(.caption2.weight(.bold)).monospacedDigit()
                    }
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Brand.accent.opacity(0.2), in: Capsule())
                .foregroundStyle(Brand.accent)
                .help(Text(model.watchQueueCount > 0
                      ? Lf("header.watch.help.queued", model.watchQueueCount)
                      : L("header.watch.help")))
            }
            Spacer()
            LanguageButton()
            ModelButton()
            SettingsLink {
                Image(systemName: "gearshape.fill").font(.title3).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L("a11y.settings")))
        }
    }
}

// MARK: - Model manager

struct ModelButton: View {
    @Environment(AppModel.self) private var model
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu").font(.caption)
                Text(friendlyModel(model.selectedModel)).font(.caption.weight(.medium)).lineLimit(1)
                if !model.isDownloaded(model.selectedModel) {
                    Image(systemName: "arrow.down.circle.fill").font(.caption).foregroundStyle(Brand.accent)
                }
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(Text(L("model.chip.help")))
        .popover(isPresented: $show, arrowEdge: .bottom) {
            ModelManagerView()
        }
    }
}

// MARK: - Recognition-language picker (global: drives dictation + file transcription)

/// Top-bar pill (paired with `ModelButton`) to pin the speech-recognition language. Default «Auto»
/// (`language == ""`) detects per-clip; pinning RU/UK/EN avoids mis-detection (Whisper often reads UK as
/// RU) and the per-window re-detect flap in streaming. Binds the same `model.language` as Settings.
struct LanguageButton: View {
    @Environment(AppModel.self) private var model

    /// Compact pill label: localized "Auto" for auto-detect, else the language code (RU/UK/EN…).
    private var pillLabel: String {
        model.language.isEmpty ? L("lang.auto.short") : model.language.uppercased()
    }

    var body: some View {
        Menu {
            Section(L("lang.menu.header")) {
                ForEach(whisperLanguages, id: \.code) { lang in
                    Button {
                        model.language = lang.code
                    } label: {
                        let title = lang.code.isEmpty ? L("lang.auto") : lang.name
                        if model.language == lang.code {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe").font(.caption)
                Text(pillLabel).font(.caption.weight(.medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(Text(L("lang.chip.help")))
    }
}

struct ModelManagerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("model.manager.title")).font(.system(.headline, design: .rounded))
            Text(L("model.manager.hint"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(spacing: 6) {
                ForEach(model.modelTiers) { tier in
                    ModelRow(tier: tier)
                }
            }
            if MLXLLMService.isSupportedHardware {
                Divider()
                Text(L("mlx.section.title")).font(.system(.subheadline, design: .rounded).weight(.semibold))
                MLXModelRow()
                Divider()
                Text(L("embed.section.title")).font(.system(.subheadline, design: .rounded).weight(.semibold))
                EmbedModelRow()
            }
            Divider()
            HStack {
                Text(L("model.disk.used")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(formatBytes(model.totalModelsBytes + model.mlxModelBytes + model.embedModelBytes)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 440)
        .task { model.refreshMLXModelState(); model.refreshEmbedModelState() }
    }
}

/// The opt-in RU/UK generative model (MLX/Qwen3) row — mirrors `ModelRow` but for the single AI model, with its
/// own download/progress/delete state (`AppModel+MLXModel.swift`). Shown only on Apple Silicon.
struct MLXModelRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(model.mlxModelDownloaded ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.tertiary))
            VStack(alignment: .leading, spacing: 1) {
                Text(L("mlx.model.title")).font(.callout).lineLimit(1)
                Text(L("mlx.model.hint")).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)   // wrap fully — don't truncate the hint
                if let err = model.mlxDownloadError, !model.mlxDownloading {
                    Text(err).font(.caption2).foregroundStyle(.red)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var trailing: some View {
        if model.mlxDownloading {
            HStack(spacing: 6) {
                ProgressView(value: model.mlxDownloadProgress).frame(width: 64)
                Text("\(Int(model.mlxDownloadProgress * 100))%").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        } else if model.mlxModelDownloaded {
            HStack(spacing: 8) {
                if model.mlxModelBytes > 0 {
                    Text(formatBytes(model.mlxModelBytes)).font(.caption2).foregroundStyle(.secondary)
                }
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Button { Task { await model.deleteMLXModel() } } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.borderless)
                .tint(.secondary)
                .help(Text(L("model.delete.help")))
                .accessibilityLabel(Text(L("model.delete.help")))
                .disabled(model.isBusy)
            }
        } else {
            HStack(spacing: 8) {
                Text(L("mlx.model.estimate")).font(.caption2).foregroundStyle(.secondary)
                Button { Task { await model.downloadMLXModel() } } label: {
                    Label(L("common.download"), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Brand.accent)
                .disabled(model.isBusy)
            }
        }
    }
}

/// The opt-in semantic-search embedding model (Qwen3-Embedding) row — mirrors `MLXModelRow` with its own
/// download / progress / delete state (`AppModel+EmbedModel.swift`). Shown only on Apple Silicon.
struct EmbedModelRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(model.embedModelDownloaded ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.tertiary))
            VStack(alignment: .leading, spacing: 1) {
                Text(L("embed.model.title")).font(.callout).lineLimit(1)
                Text(L("embed.model.hint")).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)   // wrap fully — don't truncate the hint
                if let err = model.embedDownloadError, !model.embedDownloading {
                    Text(err).font(.caption2).foregroundStyle(.red)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var trailing: some View {
        if model.embedDownloading {
            HStack(spacing: 6) {
                ProgressView(value: model.embedDownloadProgress).frame(width: 64)
                Text("\(Int(model.embedDownloadProgress * 100))%").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        } else if model.embedModelDownloaded {
            HStack(spacing: 8) {
                if model.embedModelBytes > 0 {
                    Text(formatBytes(model.embedModelBytes)).font(.caption2).foregroundStyle(.secondary)
                }
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Button { Task { await model.deleteEmbedModel() } } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.borderless)
                .tint(.secondary)
                .help(Text(L("model.delete.help")))
                .accessibilityLabel(Text(L("model.delete.help")))
                .disabled(model.isBusy)
            }
        } else {
            HStack(spacing: 8) {
                Text(L("embed.model.estimate")).font(.caption2).foregroundStyle(.secondary)
                Button { Task { await model.downloadEmbedModel() } } label: {
                    Label(L("common.download"), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Brand.accent)
                .disabled(model.isBusy)
            }
        }
    }
}

// `ModelRow` (the transcription-model tier row) now lives in `ParlaCore/ModelRowView.swift` as a public shared
// view — the macOS ModelManagerView above and the iOS ModelManagerView render the identical row.

// MARK: - Status / progress

struct StatusBar: View {
    @Environment(AppModel.self) private var model
    @AppStorage("didCompileModel") private var didCompileModel = false   // one-time first-compile hint gate

    var body: some View {
        phaseView
            // The first ANE compile (.loadingModel → .transcribing) is one-time; once it completes,
            // retire the reassurance caption so later (fast) loads don't show it.
            .onChange(of: model.phase) { _, new in
                if case .transcribing = new { didCompileModel = true }
            }
    }

    @ViewBuilder private var phaseView: some View {
        if model.isRecordingDictation {
            VStack(alignment: .leading, spacing: 8) {
                recordingChip
                if model.isStreamingDictation { streamingPreview }
            }
        } else {
            phaseChip
        }
    }

    /// Live recording indicator (dictation): a red dot + running timer + Stop. The timer re-renders
    /// every second via TimelineView (no model churn). Shown in place of the idle/empty status.
    private var recordingChip: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text(Lf("dictation.recording", fmtTime(model.recordingElapsed)))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(L("dictation.stop")) { model.stopAndTranscribeDictation() }
                    .buttonStyle(.plain).font(.callout.weight(.medium)).foregroundStyle(Brand.accent)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    /// Live streamed text while dictating in streaming mode: the confirmed prefix solid, the volatile tail
    /// dimmed. Auto-scrolls to the live edge; height-capped so it can't shove the rest of the UI. PREVIEW
    /// ONLY — the saved transcript comes from the full decode after Stop. Hidden until there's any text.
    @ViewBuilder private var streamingPreview: some View {
        let confirmed = model.dictationConfirmedText
        let hypothesis = model.dictationHypothesisText
        if !confirmed.isEmpty || !hypothesis.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        (Text(confirmed).foregroundStyle(.primary)
                         + Text(confirmed.isEmpty || hypothesis.isEmpty ? hypothesis : " " + hypothesis)
                            .foregroundStyle(.secondary))
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Color.clear.frame(height: 1).id("dictationLiveEdge")   // bottom anchor for auto-scroll
                    }
                }
                .frame(maxHeight: 140)
                .onChange(of: hypothesis) { _, _ in proxy.scrollTo("dictationLiveEdge", anchor: .bottom) }
                .onChange(of: confirmed) { _, _ in proxy.scrollTo("dictationLiveEdge", anchor: .bottom) }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder private var phaseChip: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .preparing(let n, let b):
            progressChip(Lf("status.preparing", batchLabel(n, b)), b)
        case .downloadingModel(let p):
            downloadChip(p)
        case .loadingModel:
            VStack(alignment: .leading, spacing: 6) {
                chip(L("status.loadingmodel"), busy: true)
                if Onboarding.shouldShowFirstCompileHint(isLoadingModel: true, didCompileModel: didCompileModel) {
                    Text(L("status.loadingmodel.firstrun"))
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .transcribing(let n, let b):
            progressChip(Lf("status.transcribing", batchLabel(n, b)), b)
        case .failed(let m):
            errorChip(m)
        }
    }

    /// Chip + (for a batch) a bottom determinate bar showing «how many of how many».
    private func progressChip(_ text: String, _ b: BatchProgress?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            chip(text, busy: true) {
                if model.cancelling {
                    Text(L("transcribe.cancelling")).font(.caption).foregroundStyle(.secondary)
                } else if model.currentTranscriptionTask != nil {
                    Button(L("common.cancel")) { model.cancelTranscription() }
                        .buttonStyle(.plain).font(.callout.weight(.medium)).foregroundStyle(Brand.accent)
                        .accessibilityLabel(Text(L("common.cancel")))
                }
            }
            if model.queuedCount > 0 {
                Text(Lf("queue.pending", model.queuedCount))
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
            }
            if let b, b.total > 1 {
                ProgressView(value: Double(b.done), total: Double(b.total))
                    .tint(Brand.accent)
            }
        }
    }

    private func chip<Trailing: View>(_ text: String, busy: Bool, error: Bool = false,
                                      @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        HStack(spacing: 10) {
            if busy {
                ProgressView().controlSize(.small)
            } else if error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(error ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Error chip with in-place recovery: «Try again» (re-run the last input) + a dismiss ✕.
    private func errorChip(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message)
                .font(.callout).foregroundStyle(Color.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.canRetryLast {
                Button(L("error.retry")) { model.retryLast() }
                    .buttonStyle(.plain).font(.callout.weight(.medium)).foregroundStyle(Brand.accent)
            }
            Button { model.dismissError() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L("a11y.dismiss")))
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func downloadChip(_ p: Double) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle").foregroundStyle(Brand.accent)
                Text(Lf("status.downloading", Int(p * 100))).font(.callout)
                Spacer()
            }
            ProgressView(value: p).tint(Brand.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 48))
                .foregroundStyle(Brand.gradient)
                .opacity(0.85)
            Text(L("empty.title"))
                .font(.system(.title3, design: .rounded).weight(.semibold))
            Text(L("empty.subtitle"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .padding(40)
    }
}

struct TranscriptCard: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem
    var pinned = false           // pinned layout: header + player fixed, transcript scrolls on its own + card fills height

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var editorFocused: Bool
    @State private var player = PlaybackController()
    @State private var ttsPlayer = PlaybackController()   // read-aloud (TTS) — a separate player from the note's source audio
    @State private var synthesizingTTS = false            // brief spinner while the voice synthesizes the transcript
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool
    @State private var showDigest = false      // right pane: Transcript vs Digest (per-chapter summaries) reading mode

    private var text: String { item.display(timestamps: model.showTimestamps) }
    private var justCopied: Bool { model.lastCopiedID == item.id }
    private var audioURL: URL? { AudioStore.playableURL(for: item) }
    /// A long note with generated per-chapter summaries → offer the read-only "Digest" reading mode.
    private var hasChapterDigest: Bool { !(item.chapterSummaries?.isEmpty ?? true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if pinned && !isEditing {
                // Pinned: player stays put; ONLY the transcript (+ insights/related) scrolls, filling the card height.
                playerBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        insights
                        readingBody
                        relatedNotes
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
            } else {
                // Classic: one flowing block (the page ScrollView scrolls it). Make the reading content
                // selectable/copyable — the header is excluded so its action buttons stay click-first.
                VStack(alignment: .leading, spacing: 12) {
                    insights
                    content
                    relatedNotes
                }
                .textSelection(.enabled)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
        // Pinned fills the remaining height (so the transcript scroll has room); classic sizes to content.
        .frame(maxWidth: .infinity, maxHeight: pinned ? CGFloat.infinity : nil, alignment: .top)
        // Selection change (or a new transcript): discard any in-progress edit (so we don't
        // write it into someone else's record) and reload the player with the new record's audio.
        // initial:true — also load on first appearance.
        .onChange(of: item.id, initial: true) { _, _ in
            if isEditing { cancelEdit() }
            if isEditingTitle { cancelTitleEdit() }
            showDigest = false               // ...and on the Transcript view, not the Digest
            player.load(audioURL)
            ttsPlayer.stop()                 // switching notes stops any in-progress read-aloud
            model.refreshRelatedNotes()      // the open note changed → recompute its doc↔doc "Related"
        }
        // The playback rendition is prepared ASYNC after the transcript is shown (transcription inserts the item,
        // then `keepAudio` renders the .m4a and sets `audioPlayable` a beat later), so also (re)load when the
        // playable URL first appears — not only on a note switch. Without this the player stays empty on a fresh
        // transcription and the card shows a misleading "format not supported" until the note is reopened.
        // `player.load` is idempotent by URL, so the overlap with the id-change load never double-loads.
        .onChange(of: audioURL) { _, url in player.load(url) }
        .onDisappear { player.stop(); ttsPlayer.stop() }
        // Handoff: advertise "view this transcript" while it's the open card so another device (iOS) can
        // continue it. id-only; the other device opens the note locally by id.
        .userActivity(AppModel.viewTranscriptActivityType, isActive: true) { activity in
            activity.title = item.displayTitle
            activity.userInfo = ["id": item.id.uuidString]
            activity.isEligibleForHandoff = true
        }
    }

    // MARK: Header — meta + actions (different in read vs edit mode)

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                titleView
                HStack(spacing: 6) {
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                    if item.isEdited { editedChip }
                    if model.refiningDictations.contains(item.id) { refiningChip }
                }
            }
            Spacer()
            if isEditing { editActions } else { readActions }
        }
    }

    /// The card's primary label. With titles on it's the AI/extractive (or hand-edited) title, editable
    /// inline (click → TextField; ⏎ or click-away saves, Esc cancels); with titles off it's the file name.
    @ViewBuilder private var titleView: some View {
        if model.showTitles {
            if isEditingTitle {
                TextField(L("transcript.title.placeholder"), text: $titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(.headline, design: .rounded))
                    .focused($titleFocused)
                    .onSubmit { commitTitle() }
                    .onExitCommand { cancelTitleEdit() }
                    .onChange(of: titleFocused) { _, focused in
                        if !focused, isEditingTitle { commitTitle() }   // click-away saves
                    }
            } else {
                Text(item.displayTitle)
                    .font(.system(.headline, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)   // wrap a long title onto more lines instead of truncating
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { beginTitleEdit() }
                    .help(Text(L("transcript.title.edit.help")))
            }
        } else {
            Text(item.sourceName).font(.system(.headline, design: .rounded)).lineLimit(1)
        }
    }

    /// AI insight fields under the header — the shared Core `InsightsView` (keyword tags + collapsible summary +
    /// action-items checklist). Relocated verbatim into ParlaCore so the iOS app renders it identically.
    private var insights: some View { InsightsView(item: item) }

    /// "Related notes" — the shared Core `RelatedNotesView` (doc↔doc semantic footer). Relocated verbatim into
    /// ParlaCore so the iOS app renders it identically.
    private var relatedNotes: some View { RelatedNotesView() }

    private var readActions: some View {
        HStack(spacing: 10) {
            if !model.isBusy {
                Button { beginEdit() } label: {
                    Image(systemName: "pencil").font(.body)
                        .padding(9).background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .help(Text(L("transcript.edit.help")))
                .accessibilityLabel(Text(L("transcript.edit.help")))
            }
            Button { model.copyItem(item) } label: {
                Label(justCopied ? L("common.copied") : L("common.copy"),
                      systemImage: justCopied ? "checkmark" : "doc.on.doc")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(
                        justCopied ? AnyShapeStyle(Color.green.opacity(0.3)) : AnyShapeStyle(Brand.gradient),
                        in: Capsule()
                    )
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            // Read-aloud: speak the transcript with a system voice, play via its own PlaybackController.
            // Best-effort + additive — off the isBusy lane; a synth spinner then a stop toggle while it plays.
            Button { readAloud() } label: {
                Group {
                    if synthesizingTTS { ProgressView().controlSize(.small) }
                    else { Image(systemName: ttsPlayer.isPlaying ? "stop.fill" : "speaker.wave.2.fill").font(.body) }
                }
                .padding(9).background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(synthesizingTTS)
            .help(Text(L("transcript.readaloud.help")))
            .accessibilityLabel(Text(L("transcript.readaloud")))
            RetranscribeMenu(item: item)
            if !model.isBusy {
                // Regenerate insights on demand — a small menu so the user can redo EVERYTHING or just one field.
                // Same circular idiom as the edit pencil; while it runs the glyph becomes a spinner (insight work is
                // off the isBusy lane, so it stays visible) and the menu disables to coalesce taps.
                let regenerating = model.regeneratingIDs.contains(item.id)
                Menu {
                    Button(L("regenerate.all")) { Task { await model.regenerateInsights(for: item.id) } }
                    Section(L("regenerate.only")) {
                        Button(L("transcript.title")) { Task { await model.regenerateInsight(for: item.id, field: .title) } }
                        Button(L("transcript.summary")) { Task { await model.regenerateInsight(for: item.id, field: .summary) } }
                        Button(L("transcript.keywords")) { Task { await model.regenerateInsight(for: item.id, field: .keywords) } }
                        // Tasks are generative-only — offer the item only when a generative backend can serve this note.
                        if model.ai.availability(forLanguage: item.language) == .ready {
                            Button(L("transcript.actions")) { Task { await model.regenerateInsight(for: item.id, field: .actions) } }
                        }
                    }
                } label: {
                    Group {
                        if regenerating { ProgressView().controlSize(.small) }
                        else { Image(systemName: "sparkles").font(.body) }
                    }
                    .padding(9).background(.ultraThinMaterial, in: Circle())
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .fixedSize()
                .disabled(regenerating)
                .help(Text(L("transcript.regenerate.help")))
                .accessibilityLabel(Text(L("transcript.regenerate")))
            }
            Menu {
                // What goes in the file (remembered): transcript / +insights / insights-only. A per-export choice,
                // right here, so it fits "not always" without a trip to Settings.
                Picker(L("export.content"), selection: Binding(get: { model.exportContent },
                                                               set: { model.exportContent = $0 })) {
                    ForEach(ExportContent.allCases) { Text($0.label).tag($0) }
                }
                Divider()
                ForEach(ExportFormat.allCases.filter { !$0.isSubtitle }) { fmt in
                    // In "summary only" mode, hide the formats that need the transcript body (full JSON).
                    if model.exportContent != .insightsOnly || fmt.supportsInsightsOnly {
                        Button(fmt.displayName) { model.export(item, as: fmt) }
                    }
                }
                // Subtitles grouped + labelled — the video→subtitles "killer" use case, made obvious.
                // They need the transcript body (cues), so hidden in "summary only" mode.
                if model.exportContent != .insightsOnly {
                    Section(L("export.subtitles")) {
                        ForEach(ExportFormat.allCases.filter { $0.isSubtitle }) { fmt in
                            Button(fmt.displayName) { model.export(item, as: fmt) }
                        }
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.up").font(.body)
                    .padding(9).background(.ultraThinMaterial, in: Circle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help(Text(L("export.menu.help")))
            .accessibilityLabel(Text(L("export.menu.help")))
        }
    }

    /// Speak the raw transcript aloud with a system voice. Best-effort — TTS never disrupts the note:
    /// any failure silently no-ops. Toggles play↔stop; picks a voice for the note's language, falling back to any
    /// system voice. Runs off the isBusy lane (additive), so it works even mid-transcription.
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

    private var editActions: some View {
        HStack(spacing: 8) {
            Button { cancelEdit() } label: {
                Text(L("common.cancel"))
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)   // Esc
            Button { commitEdit() } label: {
                Label(L("common.done"), systemImage: "checkmark")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Brand.gradient, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)   // ⌘↩
        }
    }

    /// Shown on a dictation saved from the live stream while the full decode refines it in place. Makes the
    /// text update EXPECTED ("it's still finalizing") instead of a surprising silent change.
    private var refiningChip: some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.mini)
            Text(L("transcript.refining"))
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Brand.accent.opacity(0.18), in: Capsule())
        .foregroundStyle(Brand.accent)
        .help(Text(L("transcript.refining.help")))
    }

    private var editedChip: some View {
        Text(L("transcript.edited"))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Brand.accent.opacity(0.18), in: Capsule())
            .foregroundStyle(Brand.accent)
            .help(Text(item.editedAt.map { Lf("transcript.edited.at", $0.formatted(date: .abbreviated, time: .shortened)) }
                  ?? L("transcript.edited.manually")))
    }

    // MARK: Body — text (reading) or editor (editing)

    @ViewBuilder private var content: some View {
        if isEditing {
            TextEditor(text: $draft)
                .font(.system(.body, design: .rounded))
                .scrollContentBackground(.hidden)          // macOS 14-safe; keeps the card's dark background
                .focused($editorFocused)
                .frame(maxWidth: .infinity, minHeight: 280, alignment: .leading)
                .padding(10)
                .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
        } else {
            VStack(spacing: 10) { playerBar; readingBody }
        }
    }

    /// The audio player + (for long notes) the Transcript⇄Digest picker. In the pinned layout this is FIXED above
    /// the scrolling transcript; in the classic layout it's the top of the flowing reading block.
    private var playerBar: some View {
        VStack(spacing: 10) {
            TransportBar(player: player, hasAudio: audioURL != nil)
            // Transcript ⇄ Digest toggle — only when a long note has per-chapter summaries to read.
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

    /// The scrolling reading content itself — the per-chapter digest or the transcript body.
    @ViewBuilder private var readingBody: some View {
        if showDigest, hasChapterDigest {
            ChapterDigestView(item: item)
        } else {
            readBody
        }
    }

    // MARK: Editing — helpers

    /// Record text: a list of tappable segments (if there are timestamps and the record isn't edited) or plain text.
    @ViewBuilder private var readBody: some View {
        if model.showTimestamps, !item.isEdited, !item.segments.isEmpty {
            if AudioChunker.isLong(durationSec: item.durationSec) {
                ChapterListView(item: item, player: player, tappable: audioURL != nil)
            } else {
                SegmentList(segments: item.segments, player: player, tappable: audioURL != nil)
            }
        } else {
            Text(text)
                .font(.system(.body, design: .rounded))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func beginEdit() {
        player.stop()              // editing text — don't play
        draft = item.text          // ALWAYS plain text, not display(timestamps:)
        isEditing = true
        editorFocused = true
    }
    private func cancelEdit() {
        isEditing = false
        editorFocused = false
    }
    private func commitEdit() {
        // saveEdit invalidates the item's vector/lemmas synchronously; kick the (async, best-effort) re-embed +
        // re-lemmatize here in the UI layer so a store mutation never spawns a Task that could outlive a test.
        if model.saveEdit(draft, for: item.id) {
            Task { await model.refreshSemanticIndex() }
        }
        isEditing = false
        editorFocused = false
    }

    private func beginTitleEdit() {
        titleDraft = item.title ?? ""   // start from the real title (empty if none) — not the sourceName fallback
        isEditingTitle = true
        titleFocused = true
    }
    private func cancelTitleEdit() {
        isEditingTitle = false
        titleFocused = false
    }
    private func commitTitle() {
        // setTitle invalidates the doc-vector synchronously (title is part of embedText); kick the re-embed here
        // in the UI layer so a store mutation never spawns a Task that could outlive a test (see commitEdit).
        if model.setTitle(titleDraft, for: item.id) {
            Task { await model.refreshSemanticIndex() }
        }
        isEditingTitle = false
        titleFocused = false
    }

    private var meta: String {
        let lang = item.language.isEmpty ? "?" : item.language.uppercased()
        let facts = "\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(lang) · \(friendlyModel(item.model)) · \(Int(item.durationSec))s · \(Lf("transcript.meta.words", item.wordCount))"
        // With titles on, the headline is the title → keep the file name visible here; otherwise it's the headline.
        return model.showTitles ? "\(item.sourceName) · \(facts)" : facts
    }
}

/// «Re-transcribe» — a dropdown of model tiers. Re-runs the record on the selected model,
/// replacing its content in place. Disabled if the engine is busy or the source is unavailable.
struct RetranscribeMenu: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem

    var body: some View {
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
            Image(systemName: "arrow.triangle.2.circlepath").font(.body)
                .padding(9).background(.ultraThinMaterial, in: Circle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!model.canRetranscribe(item))
        .help(Text(item.hasResolvableSource
              ? L("transcript.retranscribe.help")
              : L("transcript.source.unavailable")))
        .accessibilityLabel(Text(L("transcript.retranscribe.help")))
    }
}

