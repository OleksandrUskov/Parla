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
    /// Hard ceiling on the decode window: never look back further than this from the live edge, so a stalled
    /// cursor (zero-segment silence with VAD off, or speech before the first confirm) can't grow the decode
    /// or the lock-held buffer copy without bound. Must exceed streamFlushSpan so normal speech advances via
    /// flush (no audio skipped) and only silence is ever clamped past.
    private static let streamMaxWindowSamples = 240_000   // 15 s @ 16 kHz

    /// Where to start the next decode window (sample index): the confirmed cursor, but never more than
    /// `maxWindow` behind the live edge. Pure + nonisolated → unit-tested. Audio skipped by the clamp is only
    /// ever silence/unconfirmable (speech advances the cursor via flush); the saved transcript is the full
    /// decode regardless, so the clamp only ever trims the live preview, never stored text.
    nonisolated static func streamWindowStartSample(cursorSample: Int, liveCount: Int, maxWindow: Int) -> Int {
        max(cursorSample, liveCount - maxWindow)
    }

    /// True while a streaming decode loop is actually running — drives the live-preview visibility.
    /// LOOP-driven, not setting-driven, so flipping the Settings toggle mid-dictation can't surface a
    /// frozen, decoding-nothing preview (the loop only starts at startDictation when streaming was on).
    var isStreamingDictation: Bool { streamingTask != nil }

    /// Pure (unit-tested): the language to use for the next streaming window. An explicit `current` is kept;
    /// on "Auto" (`current == nil`) the first non-empty `detected` language is pinned so later short windows
    /// don't re-detect and flap (the RU/UK guardrail — never auto-detect per window).
    nonisolated static func lockedLanguage(current: String?, detected: String) -> String? {
        current ?? (detected.isEmpty ? nil : detected)
    }

    /// Pure (unit-tested): re-pin the streaming language lock when the user changes the explicit pick
    /// mid-dictation. If `explicit` differs from `lastExplicit`, adopt it (a new language, or nil = back to
    /// auto-detect); otherwise keep the current `locked` (which `lockedLanguage` may have auto-pinned).
    nonisolated static func repinnedLanguage(explicit: String?, lastExplicit: String?, locked: String?)
        -> (locked: String?, lastExplicit: String?) {
        explicit != lastExplicit ? (explicit, explicit) : (locked, lastExplicit)
    }

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
            // Lock the language after the first detection: on "Auto" (lang == nil) short streaming windows
            // otherwise re-detect every tick and can flap (RU↔EN), which is a big chunk of the RU garbage.
            // Once a window comes back with a language, pin it for all later windows. (If the user set a
            // language explicitly, it's already pinned.)
            var lockedLang = lang
            var lastExplicit = lang   // the user's explicit pick; re-pin if the language pill changes mid-dictation
            while !Task.isCancelled {
                try? await Task.sleep(for: AppModel.streamingInterval)
                // Re-validate after every suspension: the recording may have stopped, or a NEW dictation may
                // have replaced this recorder (then this loop is stale and must exit).
                guard !Task.isCancelled, let self, let recorder,
                      recorder.isRecording, self.recorder === recorder else { break }

                // If the user changed the language pill mid-dictation, re-pin to the new explicit choice
                // (or back to auto-detect) so the live preview matches the language the saved decode will use.
                let repin = AppModel.repinnedLanguage(explicit: self.language.isEmpty ? nil : self.language,
                                                      lastExplicit: lastExplicit, locked: lockedLang)
                lockedLang = repin.locked; lastExplicit = repin.lastExplicit

                let cursorSample = Int(reconciler.confirmedSeconds * AppModel.streamSampleRate)
                let from = AppModel.streamWindowStartSample(cursorSample: cursorSample,
                                                            liveCount: recorder.liveSampleCount,
                                                            maxWindow: AppModel.streamMaxWindowSamples)
                let window = recorder.liveSamples(from: from)
                guard window.count >= AppModel.streamMinWindowSamples else { continue }
                // windowStart from the actual sample index (not confirmedSeconds) so the seconds cursor and
                // the sample cursor stay exactly consistent — no rounding drift, and correct when the clamp
                // skips ahead of a stalled cursor.
                let windowStart = Double(from) / AppModel.streamSampleRate
                let flush = Double(window.count) / AppModel.streamSampleRate >= AppModel.streamFlushSpan

                guard let r = try? await self.engine.transcribe(samples: window, language: lockedLang, model: model)
                else { continue }   // transient decode error → keep streaming
                guard !Task.isCancelled, self.recorder === recorder else { break }
                lockedLang = AppModel.lockedLanguage(current: lockedLang, detected: r.language)   // pin after 1st detect

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
