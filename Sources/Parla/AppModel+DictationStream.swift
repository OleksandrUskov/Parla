import Foundation

/// Live segment-level streaming preview (MIC_DICTATION P3).
///
/// While a dictation records in streaming mode, a loop decodes a sliding window of the captured audio every
/// `streamingInterval` and feeds it to a `StreamingReconciler`, publishing a confirmed prefix + dimmed
/// hypothesis tail for the UI. This is **preview only**: on stop the standard `finishDictation(wav:)` does a
/// full offline decode for the *saved* transcript, so streaming artifacts (RU/UK chunk-boundary degradation,
/// word-end truncation) never reach stored text.
///
/// Concurrency: AppModel is `@MainActor`, so the loop body runs on the main actor; only the engine decode
/// `await`s off-main (on the `TranscriptionEngine` actor), so the UI never blocks. Audio never crosses
/// isolation — the loop pulls a `Sendable` `[Float]` snapshot from the recorder and hands it to the engine.
extension AppModel {
    /// 16 kHz mono — the recorder's `targetFormat` rate. Maps the reconciler's seconds cursor to a sample
    /// index for `MicRecorder.liveSamples(from:)`.
    private static let streamSampleRate = 16_000.0
    /// How often to re-decode the sliding window. Segment-level "near-live", not token-by-token.
    private static let streamingInterval: Duration = .milliseconds(1500)
    /// Don't decode a window shorter than this — sub-second clips decode poorly (especially RU/UK).
    private static let streamMinWindowSamples = 12_000   // 0.75 s
    /// If the decode window grows past this without the cursor advancing (continuous low-pause speech),
    /// force-flush so the cursor catches up — bounds each decode + the audio-thread lock-copy.
    private static let streamFlushSpan = 10.0   // seconds

    /// True while a streaming decode loop is actually running — drives the live-preview visibility.
    /// LOOP-driven, not setting-driven, so flipping the Settings toggle mid-dictation can't surface a
    /// frozen, decoding-nothing preview (the loop only starts at startDictation when streaming was on).
    var isStreamingDictation: Bool { streamingTask != nil }

    /// Start the live decode loop for `recorder`. Single-flight (cancels any prior loop). Best-effort: a
    /// transient decode error just skips a frame; a missing model means no preview (the final
    /// `finishDictation` surfaces the real error).
    func startStreamingLoop(for recorder: MicRecorder) {
        stopStreamingLoop()   // cancel + clear any prior loop/preview before starting fresh
        // Only stream when the model is already on disk: otherwise the pre-warm would silently download a
        // multi-hundred-MB model with no UI. Graceful absence — no live preview, but the dictation still
        // records and the final finishDictation downloads (with progress UI) for the saved transcript.
        guard TranscriptionEngine.isDownloaded(selectedModel) else { return }
        let model = selectedModel
        let lang = language.isEmpty ? nil : language   // explicit for RU/UK; nil → engine auto-detects
        streamingTask = Task { [weak self, weak recorder] in
            // Pre-warm the (already-downloaded) model so the first window isn't a load stall.
            try? await self?.engine.ensureLoaded(model: model, progress: { _ in })
            var reconciler = StreamingReconciler()
            while !Task.isCancelled {
                try? await Task.sleep(for: AppModel.streamingInterval)
                // Re-validate after every suspension: the recording may have stopped, or a NEW dictation may
                // have replaced this recorder (then this loop is stale and must exit).
                guard !Task.isCancelled, let self, let recorder,
                      recorder.isRecording, self.recorder === recorder else { break }

                let from = Int(reconciler.confirmedSeconds * AppModel.streamSampleRate)
                let window = recorder.liveSamples(from: from)
                guard window.count >= AppModel.streamMinWindowSamples else { continue }
                // windowStart from the actual sample index (not confirmedSeconds) so the seconds cursor and
                // the sample cursor stay exactly consistent — no rounding drift accumulating over many ticks.
                let windowStart = Double(from) / AppModel.streamSampleRate
                let flush = Double(window.count) / AppModel.streamSampleRate >= AppModel.streamFlushSpan

                guard let r = try? await self.engine.transcribe(samples: window, language: lang, model: model)
                else { continue }   // transient decode error → keep streaming
                guard !Task.isCancelled, self.recorder === recorder else { break }

                reconciler.ingest(segments: r.segments, windowStart: windowStart, flush: flush)
                self.dictationConfirmedText = reconciler.confirmedText
                self.dictationHypothesisText = reconciler.hypothesisText
            }
        }
    }

    /// Stop the live decode loop and clear the preview. The saved transcript comes from the full decode in
    /// `finishDictation`, so nothing here needs flushing — the loop just stops, and clearing the published
    /// text here (not only on the next start) keeps stale preview from flashing into the next session.
    func stopStreamingLoop() {
        streamingTask?.cancel()
        streamingTask = nil
        dictationConfirmedText = ""
        dictationHypothesisText = ""
    }
}
