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

    /// True while a streaming preview should be shown (opt-in mode + actively recording).
    var isStreamingDictation: Bool { dictationLiveStreaming && isRecordingDictation }

    /// Start the live decode loop for `recorder`. Single-flight (cancels any prior loop). Best-effort: a
    /// transient decode error just skips a frame; a missing model means no preview (the final
    /// `finishDictation` surfaces the real error).
    func startStreamingLoop(for recorder: MicRecorder) {
        streamingTask?.cancel()
        dictationConfirmedText = ""
        dictationHypothesisText = ""
        let model = selectedModel
        let lang = language.isEmpty ? nil : language   // explicit for RU/UK; nil → engine auto-detects
        streamingTask = Task { [weak self, weak recorder] in
            // Pre-warm the model so the first window isn't a long stall while audio piles up.
            try? await self?.engine.ensureLoaded(model: model, progress: { _ in })
            var reconciler = StreamingReconciler()
            while !Task.isCancelled {
                try? await Task.sleep(for: AppModel.streamingInterval)
                // Re-validate after every suspension: the recording may have stopped, or a NEW dictation may
                // have replaced this recorder (then this loop is stale and must exit).
                guard !Task.isCancelled, let self, let recorder,
                      recorder.isRecording, self.recorder === recorder else { break }

                let windowStart = reconciler.confirmedSeconds
                let from = Int(windowStart * AppModel.streamSampleRate)
                let window = recorder.liveSamples(from: from)
                guard window.count >= AppModel.streamMinWindowSamples else { continue }

                guard let r = try? await self.engine.transcribe(samples: window, language: lang, model: model)
                else { continue }   // transient decode error → keep streaming
                guard !Task.isCancelled, self.recorder === recorder else { break }

                reconciler.ingest(segments: r.segments, windowStart: windowStart)
                self.dictationConfirmedText = reconciler.confirmedText
                self.dictationHypothesisText = reconciler.hypothesisText
            }
        }
    }

    /// Stop the live decode loop. The saved transcript comes from the full decode in `finishDictation`, so
    /// nothing here needs to be flushed — the loop just stops updating the preview.
    func stopStreamingLoop() {
        streamingTask?.cancel()
        streamingTask = nil
    }
}
