import SwiftUI
import UniformTypeIdentifiers
import ParlaCore

// Shell-agnostic History pieces (iOS-port P2.2a) reused by BOTH the compact shell (HistoryListView, a
// NavigationStack) and the iPad split shell (HistorySplitView, a NavigationSplitView) — extracted so the two
// shells share ONE definition of the row, the busy/recording/failed/empty state views, and the import machinery
// instead of duplicating them. Pure presentation over the shared Core model; no navigation assumptions.

/// One history row — mirrors the macOS `SidebarRow` content (title · 2-line snippet · date) as a floating card
/// over the Aurora list. Swipe (compact) / selection (split) replace the macOS hover-delete + selection.
struct HistoryRow: View {
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

/// Busy = copying an import, downloading the model (determinate), the one-time ANE compile, or transcribing.
/// A long recording chunks into an "N of M" pass (`BatchProgress`) — a multi-file batch too — so both get a
/// determinate bar instead of a bare spinner. Includes Cancel + queued-count (mirrors the macOS progressChip).
struct HistoryBusyView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
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
                // Cancel lands at the next file/chunk boundary (WhisperKit can't abort mid-decode) → "Stopping…".
                if model.cancelling {
                    Text(L("transcribe.cancelling")).font(.caption).foregroundStyle(.secondary)
                } else if model.currentTranscriptionTask != nil {
                    Button(L("common.cancel")) { model.cancelTranscription() }
                        .buttonStyle(.bordered).tint(Brand.accent)
                }
                if model.queuedCount > 0 {
                    Text(Lf("queue.pending", model.queuedCount))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            default:
                ProgressView().controlSize(.large)
                Text(busyLabel).font(.callout).foregroundStyle(.secondary)
            }
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
}

/// Shown while recording a dictation: a pulsing mic + running timer, the live streaming preview (confirmed
/// solid + hypothesis dimmed) when live-streaming is on, and a big Stop that ends capture and transcribes.
/// The transcript inference itself is device-only (WhisperKit crashes on the sim, no ANE).
struct HistoryRecordingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            // TimelineView keeps the elapsed timer ticking (recordingElapsed is derived from a start Date).
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                VStack(spacing: 10) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 68))
                        .foregroundStyle(Brand.gradient)
                        .symbolEffect(.pulse)
                    Text(Lf("dictation.recording", fmtTime(model.recordingElapsed)))
                        .font(.title3.monospacedDigit().weight(.semibold))
                }
            }
            if model.isStreamingDictation {
                ScrollView {
                    (Text(model.dictationConfirmedText)
                     + Text(model.dictationConfirmedText.isEmpty || model.dictationHypothesisText.isEmpty ? "" : " ")
                     + Text(model.dictationHypothesisText).foregroundColor(.secondary))
                        .font(.system(.body, design: .rounded))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                .padding(14)
                .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
            }
            Button { model.stopAndTranscribeDictation() } label: {
                Label(L("dictation.stop"), systemImage: "stop.circle.fill").font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(32)
    }
}

/// A failed run: message + in-place recovery (Try again / Dismiss) so the user is never stranded with their
/// existing transcripts hidden behind the error.
struct HistoryFailedView: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(.orange)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
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
}

/// Empty history — the "Ready to go" hero + a choose-file button (the import action is the caller's).
struct HistoryEmptyView: View {
    var onChoose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(Brand.gradient)
            Text(L("empty.title")).font(.title2.weight(.semibold))
            Text(L("empty.subtitle"))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { onChoose() } label: {
                Label(L("drop.choose"), systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.accent)
            .padding(.top, 4)
        }
        .padding(32)
    }
}

/// Import machinery shared by both shells.
enum HistoryImport {
    /// Audio + video containers + Telegram Ogg/Opus (+ flac) by extension — a Telegram `.ogg` resolves to the
    /// same dynamic UTI this produces, so it's selectable without a bundled UTI declaration.
    static var types: [UTType] {
        var t: [UTType] = [.audio, .movie, .mpeg4Audio, .mp3, .wav]
        for ext in ["ogg", "oga", "opus", "flac"] {
            if let u = UTType(filenameExtension: ext) { t.append(u) }
        }
        return t
    }
}
