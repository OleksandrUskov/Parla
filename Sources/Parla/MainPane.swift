import SwiftUI

struct MainPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            BrandHeader()
            DropZoneView().frame(height: 210)
            StatusBar()
            if let item = model.selectedItem {
                TranscriptCard(item: item)
            } else {
                EmptyState()
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            Divider()
            HStack {
                Text(L("model.disk.used")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(formatBytes(model.totalModelsBytes)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 440)
    }
}

struct ModelRow: View {
    @Environment(AppModel.self) private var model
    let tier: ModelTier

    private var isSelected: Bool { model.selectedModel == tier.name }
    private var isDownloaded: Bool { model.isDownloaded(tier.name) }
    private var isDownloading: Bool { model.downloadingModel == tier.name }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.tertiary))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(tier.title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    if tier.recommended {
                        Text(L("model.recommended")).font(.caption2.weight(.bold)).foregroundStyle(Brand.accent)
                    }
                }
                Text(tier.hint).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(8)
        .background(
            isSelected ? AnyShapeStyle(Brand.gradient.opacity(0.18)) : AnyShapeStyle(Color.white.opacity(0.04)),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectedModel = tier.name }
    }

    @ViewBuilder private var trailing: some View {
        if isDownloading {
            HStack(spacing: 6) {
                ProgressView(value: model.downloadProgress).frame(width: 64)
                Text("\(Int(model.downloadProgress * 100))%").font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        } else if isDownloaded {
            HStack(spacing: 8) {
                if let bytes = model.modelSizes[tier.name] {
                    Text(formatBytes(bytes)).font(.caption2).foregroundStyle(.secondary)
                }
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Button { Task { await model.deleteModel(tier.name) } } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.borderless)
                .tint(.secondary)
                .help(Text(L("model.delete.help")))
                .accessibilityLabel(Text(L("model.delete.help")))
                .disabled(model.downloadingModel != nil || model.isBusy)
            }
        } else {
            HStack(spacing: 8) {
                if !tier.estimate.isEmpty {
                    Text(tier.estimate).font(.caption2).foregroundStyle(.secondary)
                }
                Button { Task { await model.downloadModel(tier.name) } } label: {
                    Label(L("common.download"), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Brand.accent)
                .disabled(model.downloadingModel != nil || model.isBusy)
            }
        }
    }
}

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
            chip(text, busy: true)
            if let b, b.total > 1 {
                ProgressView(value: Double(b.done), total: Double(b.total))
                    .tint(Brand.accent)
            }
        }
    }

    private func chip(_ text: String, busy: Bool, error: Bool = false) -> some View {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct TranscriptCard: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var editorFocused: Bool
    @State private var player = PlaybackController()

    private var text: String { item.display(timestamps: model.showTimestamps) }
    private var justCopied: Bool { model.lastCopiedID == item.id }
    private var audioURL: URL? { AudioStore.playableURL(for: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Selection change (or a new transcript): discard the in-progress edit (so we don't
        // write it into someone else's record) and reload the player with the new record's audio.
        // initial:true — also load on first appearance.
        .onChange(of: item.id, initial: true) { _, _ in
            if isEditing { cancelEdit() }
            player.load(audioURL)
        }
        .onDisappear { player.stop() }
    }

    // MARK: Header — meta + actions (different in read vs edit mode)

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.sourceName).font(.system(.headline, design: .rounded)).lineLimit(1)
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
            RetranscribeMenu(item: item)
            Menu {
                ForEach(ExportFormat.allCases) { fmt in
                    Button(fmt.displayName) { model.export(item, as: fmt) }
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
                .frame(maxWidth: .infinity, minHeight: 160, maxHeight: .infinity, alignment: .leading)
                .padding(10)
                .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
        } else {
            VStack(spacing: 10) {
                TransportBar(player: player, hasAudio: audioURL != nil)
                readBody
            }
        }
    }

    // MARK: Editing — helpers

    /// Record text: a list of tappable segments (if there are timestamps and the record isn't edited) or plain text.
    @ViewBuilder private var readBody: some View {
        if model.showTimestamps, !item.isEdited, !item.segments.isEmpty {
            if AudioChunker.isLong(durationSec: item.durationSec) {
                ChapterListView(segments: item.segments, player: player, tappable: audioURL != nil)
            } else {
                SegmentList(segments: item.segments, player: player, tappable: audioURL != nil)
            }
        } else {
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .rounded))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
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
        model.saveEdit(draft, for: item.id)
        isEditing = false
        editorFocused = false
    }

    private var meta: String {
        let lang = item.language.isEmpty ? "?" : item.language.uppercased()
        return "\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(lang) · \(friendlyModel(item.model)) · \(Int(item.durationSec))s · \(Lf("transcript.meta.words", item.wordCount))"
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

// MARK: - Source audio player (feature 06)

/// Transport: play/pause + scrubber + time. Degrades to a single note line if there's no audio
/// or the format isn't playable by the built-in player.
struct TransportBar: View {
    let player: PlaybackController
    let hasAudio: Bool

    var body: some View {
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
struct SegmentList: View {
    let segments: [Segment]
    let player: PlaybackController
    let tappable: Bool

    private var activeIdx: Int? { activeSegmentIndex(segments, at: player.currentTime) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                    if !seg.cleanText.isEmpty {
                        SegmentRow(seg: seg, active: i == activeIdx, tappable: tappable)
                            .contentShape(Rectangle())
                            .onTapGesture { if tappable { player.seek(to: seg.start) } }
                    }
                }
            }
            .padding(12)
        }
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct SegmentRow: View {
    let seg: Segment
    let active: Bool
    let tappable: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("[\(fmtTime(seg.start))]")
                .font(.caption.monospacedDigit())
                .foregroundStyle(active || tappable ? AnyShapeStyle(Brand.accent) : AnyShapeStyle(.tertiary))
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
struct ChapterListView: View {
    let segments: [Segment]
    let player: PlaybackController
    let tappable: Bool

    private var chapters: [Chapter] { AudioChunker.chapters(from: segments) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(chapters) { chapter in
                    ChapterSection(chapter: chapter, player: player, tappable: tappable,
                                   initiallyExpanded: chapter.index == 0)
                }
            }
            .padding(12)
        }
        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ChapterSection: View {
    let chapter: Chapter
    let player: PlaybackController
    let tappable: Bool
    @State private var expanded: Bool

    init(chapter: Chapter, player: PlaybackController, tappable: Bool, initiallyExpanded: Bool) {
        self.chapter = chapter
        self.player = player
        self.tappable = tappable
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(chapter.segments.enumerated()), id: \.offset) { _, seg in
                    if !seg.cleanText.isEmpty {
                        SegmentRow(seg: seg, active: false, tappable: tappable)
                            .contentShape(Rectangle())
                            .onTapGesture { if tappable { player.seek(to: seg.start) } }
                    }
                }
            }
            .padding(.top, 2)
        } label: {
            HStack(spacing: 8) {
                Text(Lf("chapter.title", chapter.index + 1))
                    .font(.callout.weight(.semibold))
                Text(chapter.rangeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .tint(Brand.accent)
        .padding(.horizontal, 6).padding(.vertical, 4)
    }
}
