import XCTest
import os
import AVFoundation
import AppKit
@testable import ParlaCore
@testable import Parla

/// Dictation: the streaming engine seam, the reconciler, the hybrid save that refines streamed text with a full decode, and the VAD.
final class StreamingDictationTests: ParlaLogicTestCase {
    // MARK: Dictation

    /// The recorder writes WhisperKit's native input format. If this constant drifts, dictation would
    /// silently produce the wrong sample rate / channel count and tank recognition quality. (The live
    /// mic path itself is manual-only — this pins the one piece that's pure and regressable.)
    @MainActor
    func testDictationTargetFormatIs16kMonoInt16() {
        let f = MicRecorder.targetFormat
        XCTAssertEqual(f.sampleRate, 16_000)
        XCTAssertEqual(f.channelCount, 1)
        XCTAssertEqual(f.commonFormat, .pcmFormatInt16)
    }


    // MARK: Streaming engine seam

    /// The streaming seam decodes an in-memory Float buffer and threads results through the SAME mapping
    /// as the file path. The real WhisperKit decode is manual-only; this pins the seam's shape + that the
    /// orchestrator gets a buffer-sized, canned-result double to drive.
    func testStreamingSeamDecodesBufferAndReportsSize() async throws {
        let canned = EngineResult(text: "привет", language: "ru",
                                  segments: [Segment(start: 0, end: 1, text: "привет")], duration: 1)
        let fake = FakeEngine(results: [canned])
        let r = try await fake.transcribe(samples: [Float](repeating: 0, count: 16_000),
                                          language: "ru", model: "m")
        XCTAssertEqual(r.text, "привет")
        XCTAssertEqual(r.segments.count, 1)
        XCTAssertEqual(fake.transcribedSampleCounts, [16_000])
        XCTAssertEqual(fake.transcribeCalls, 1)
    }

    /// The streaming Float feed must be bit-identical to how WhisperKit reads an Int16 WAV (÷32768) — if it
    /// drifts (e.g. ÷32767), the live path and the file path would decode subtly different samples. The live
    /// tap itself is manual-only; this pins the one pure piece. (Int16 min −32768 → exactly −1.0.)
    func testStreamingNormalizeMatchesWhisperKitWavScaling() {
        XCTAssertEqual(MicRecorder.normalize([0]), [0])
        XCTAssertEqual(MicRecorder.normalize([-32768]), [-1.0])
        XCTAssertEqual(MicRecorder.normalize([16384]), [0.5])
        XCTAssertEqual(MicRecorder.normalize([32767]).first!, 32767.0 / 32768.0, accuracy: 1e-7)
        XCTAssertEqual(MicRecorder.normalize([]).count, 0)
    }

    /// Launch pre-warm fires only for users who dictate (hotkey on) AND when the model is already on disk
    /// (never start a download from a pre-warm).
    func testShouldPrewarmModelGate() {
        XCTAssertTrue(AppModel.shouldPrewarmModel(dictationHotkeyEnabled: true, modelDownloaded: true))
        XCTAssertFalse(AppModel.shouldPrewarmModel(dictationHotkeyEnabled: true, modelDownloaded: false))
        XCTAssertFalse(AppModel.shouldPrewarmModel(dictationHotkeyEnabled: false, modelDownloaded: true))
        XCTAssertFalse(AppModel.shouldPrewarmModel(dictationHotkeyEnabled: false, modelDownloaded: false))
    }

    /// Streaming language is pinned after the first detection so short windows don't flap (RU/UK guardrail).
    func testLockedLanguagePinsAfterFirstDetect() {
        XCTAssertEqual(AppModel.lockedLanguage(current: "ru", detected: "en"), "ru")   // explicit / already-locked wins
        XCTAssertEqual(AppModel.lockedLanguage(current: nil, detected: "ru"), "ru")    // Auto → lock the first detection
        XCTAssertNil(AppModel.lockedLanguage(current: nil, detected: ""))              // nothing detected yet → stay Auto
        XCTAssertEqual(AppModel.lockedLanguage(current: "uk", detected: ""), "uk")     // keep current on an empty detect
    }


    // MARK: Streaming reconciler

    private func seg(_ start: Double, _ end: Double, _ text: String) -> Segment {
        Segment(start: start, end: end, text: text)
    }

    /// Confirm all but the last `holdback` segments; the tail is the dimmed hypothesis; the cursor advances
    /// to the last confirmed segment's absolute end.
    func testReconcilerConfirmsAllButHoldback() {
        var r = StreamingReconciler(holdback: 2)
        r.ingest(segments: [seg(0, 1, "a"), seg(1, 2, "b"), seg(2, 3, "c")], windowStart: 0)
        XCTAssertEqual(r.confirmedText, "a")
        XCTAssertEqual(r.hypothesisText, "b c")
        XCTAssertEqual(r.confirmedSeconds, 1, accuracy: 1e-9)
        XCTAssertEqual(r.liveText, "a b c")
    }

    /// With ≤ holdback segments nothing is stable yet: confirm nothing, hold the cursor, everything is hypothesis.
    func testReconcilerWithholdsWhenTooFewSegments() {
        var r = StreamingReconciler(holdback: 2)
        r.ingest(segments: [seg(0, 1, "only"), seg(1, 2, "two")], windowStart: 0)
        XCTAssertEqual(r.confirmedText, "")
        XCTAssertEqual(r.hypothesisText, "only two")
        XCTAssertEqual(r.confirmedSeconds, 0, accuracy: 1e-9)
    }

    /// Across ticks the confirmed text accumulates IN ORDER with no double-counting: segments that were the
    /// hypothesis tail one tick get confirmed the next (the window restarts at the advanced cursor).
    func testReconcilerAccumulatesAcrossTicksNoDoubleCount() {
        var r = StreamingReconciler(holdback: 2)
        // Tick 1: window @0 → confirm "a", hold "b c".
        r.ingest(segments: [seg(0, 1, "a"), seg(1, 2, "b"), seg(2, 3, "c")], windowStart: 0)
        // Tick 2: window restarts @ confirmedSeconds (1.0); decode is window-relative → "b c" now confirm-able.
        r.ingest(segments: [seg(0, 1, "b"), seg(1, 2, "c"), seg(2, 3, "d"), seg(3, 4, "e")],
                 windowStart: r.confirmedSeconds)
        XCTAssertEqual(r.confirmedText, "a b c")          // b, c counted exactly once
        XCTAssertEqual(r.hypothesisText, "d e")
        XCTAssertEqual(r.confirmedSeconds, 3, accuracy: 1e-9)   // 1.0 windowStart + 2.0 last confirmed end
    }

    /// An empty (silent) window doesn't disturb the confirmed prefix or cursor; it just clears the hypothesis.
    func testReconcilerEmptyWindowKeepsConfirmed() {
        var r = StreamingReconciler(holdback: 2)
        r.ingest(segments: [seg(0, 1, "a"), seg(1, 2, "b"), seg(2, 3, "c")], windowStart: 0)
        r.ingest(segments: [], windowStart: r.confirmedSeconds)
        XCTAssertEqual(r.confirmedText, "a")
        XCTAssertEqual(r.hypothesisText, "")
        XCTAssertEqual(r.confirmedSeconds, 1, accuracy: 1e-9)
    }

    /// holdback 0 confirms everything (a "flush"-style decode), nothing held back.
    func testReconcilerHoldbackZeroConfirmsAll() {
        var r = StreamingReconciler(holdback: 0)
        r.ingest(segments: [seg(0, 1, "a"), seg(1, 2, "b")], windowStart: 5)
        XCTAssertEqual(r.confirmedText, "a b")
        XCTAssertEqual(r.hypothesisText, "")
        XCTAssertEqual(r.confirmedSeconds, 7, accuracy: 1e-9)   // 5 windowStart + 2 last end
    }

    /// Joining trims each segment, drops empties, and uses single spaces (Whisper segment text often carries
    /// leading spaces / blank tokens after stripping).
    func testReconcilerJoinNormalizesSpacing() {
        var r = StreamingReconciler(holdback: 0)
        r.ingest(segments: [seg(0, 1, "  hello "), seg(1, 2, ""), seg(2, 3, " world")], windowStart: 0)
        XCTAssertEqual(r.confirmedText, "hello world")
    }

    /// `flush: true` overrides holdback and confirms every segment, advancing the cursor — the orchestrator
    /// uses this when the window has grown large without confirming (continuous speech), to keep it bounded.
    func testReconcilerFlushConfirmsAllSegmentsDespiteHoldback() {
        var r = StreamingReconciler(holdback: 2)
        r.ingest(segments: [seg(0, 1, "a"), seg(1, 2, "b"), seg(2, 3, "c")], windowStart: 0, flush: true)
        XCTAssertEqual(r.confirmedText, "a b c")          // all confirmed despite holdback 2
        XCTAssertEqual(r.hypothesisText, "")
        XCTAssertEqual(r.confirmedSeconds, 3, accuracy: 1e-9)
    }

    /// Overlap-aware merge drops ONLY the single boundary word a re-decoded window can re-emit — never a
    /// longer run (that would eat genuinely repeated speech, the regression the re-review caught).
    func testReconcilerMergeDedupDropsSingleBoundaryWord() {
        XCTAssertEqual(StreamingReconciler.mergeDedup("привет", "привет мир"), "привет мир")     // re-emit removed
        XCTAssertEqual(StreamingReconciler.mergeDedup("раз два три", "три четыре"), "раз два три четыре")
        XCTAssertEqual(StreamingReconciler.mergeDedup("a b", "c d"), "a b c d")                 // no overlap
        XCTAssertEqual(StreamingReconciler.mergeDedup("так", "так"), "так")                     // pure single re-emit
        XCTAssertEqual(StreamingReconciler.mergeDedup("", "hello"), "hello")
        XCTAssertEqual(StreamingReconciler.mergeDedup("done", ""), "done")
        // A genuinely repeated run is PRESERVED (minus only the one boundary word) — NOT collapsed.
        XCTAssertEqual(StreamingReconciler.mergeDedup("да да да", "да да да да да"), "да да да да да да да")
    }

    /// The decode window is clamped to a max look-back so a stalled cursor (zero-segment silence / pre-first
    /// confirm) can't grow the decode or the lock-held copy without bound.
    func testStreamWindowStartClampsToMaxLookback() {
        let maxW = 240_000   // 15 s @ 16 kHz
        // Cursor recent → start at the cursor (no clamp).
        XCTAssertEqual(AppModel.streamWindowStartSample(cursorSample: 100_000, liveCount: 120_000, maxWindow: maxW), 100_000)
        // Cursor stalled far back → clamp to liveCount - maxWindow.
        XCTAssertEqual(AppModel.streamWindowStartSample(cursorSample: 0, liveCount: 400_000, maxWindow: maxW), 160_000)
        // Buffer shorter than the window → start at the cursor (0).
        XCTAssertEqual(AppModel.streamWindowStartSample(cursorSample: 0, liveCount: 50_000, maxWindow: maxW), 0)
    }

    /// End-to-end: a tick whose re-decoded window re-emits the prior confirmed word must NOT duplicate it.
    func testReconcilerNoDuplicateWordAcrossReSegmentedWindow() {
        var r = StreamingReconciler(holdback: 2)
        r.ingest(segments: [seg(0, 1, "a"), seg(1, 2, "b"), seg(2, 3, "c")], windowStart: 0)   // confirm "a"
        // Next window restarts at the cursor (1.0) but re-emits "a" first (cut landed before a's acoustic end).
        r.ingest(segments: [seg(0, 1, "a"), seg(1, 2, "b"), seg(2, 3, "c"), seg(3, 4, "d")], windowStart: 1.0)
        XCTAssertEqual(r.confirmedText, "a b")            // "a" not duplicated, "b" confirmed
        XCTAssertEqual(r.hypothesisText, "c d")
    }


    // MARK: Hybrid streaming save (refine the instant streamed text with a full decode)

    /// The streamed text is saved instantly, then the full decode REPLACES it in place and the refining
    /// badge clears.
    @MainActor func testRefineDictationReplacesStreamedWithFullDecode() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "полный точный декод", language: "ru", segments: [], duration: 3)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.refineDictation(wav: wav, streamed: "стрим текст", id: UUID())

            XCTAssertEqual(m.history.count, 1)
            XCTAssertEqual(m.history.first?.text, "полный точный декод")   // refined to the full decode
            XCTAssertTrue(m.refiningDictations.isEmpty)                    // badge cleared
            XCTAssertNil(m.history.first?.sourcePath)                      // dictation → no source
            XCTAssertEqual(fake.transcribeCalls, 1)
        }
    }

    /// An empty full decode must NOT blank the instant result — the streamed text is kept.
    @MainActor func testRefineDictationKeepsStreamedWhenDecodeEmpty() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "   ", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.refineDictation(wav: wav, streamed: "стрим текст", id: UUID())

            XCTAssertEqual(m.history.count, 1)
            XCTAssertEqual(m.history.first?.text, "стрим текст")   // instant result kept
            XCTAssertTrue(m.refiningDictations.isEmpty)
        }
    }

    /// A failed full decode keeps the instant streamed result (already saved/copied/pasted) — nothing lost.
    @MainActor func testRefineDictationKeepsStreamedWhenDecodeFails() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(throwOnTranscribe: true)
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.refineDictation(wav: wav, streamed: "стрим текст", id: UUID())

            XCTAssertEqual(m.history.count, 1)
            XCTAssertEqual(m.history.first?.text, "стрим текст")   // survives a failed refine
            XCTAssertTrue(m.refiningDictations.isEmpty)
        }
    }

    /// A refining dictation holds the single-flight lane (isBusy) so no concurrent job (folder-watch, drop, a
    /// new dictation) starts mid-refine and the edit pencil stays hidden — the fix for the lane/clobber HIGHs.
    @MainActor func testRefiningDictationHoldsBusyLane() {
        let m = AppModel(engine: FakeEngine())
        m.history = []
        XCTAssertFalse(m.isBusy)
        let id = UUID()
        m.refiningDictations.insert(id)
        XCTAssertTrue(m.isBusy)            // refine in flight → busy
        m.refiningDictations.remove(id)
        XCTAssertFalse(m.isBusy)           // released
    }

    /// A refine holds the busy lane but must NOT trigger the quit "work will be lost" prompt — its streamed
    /// transcript is already on disk; only the optional accuracy upgrade is in flight.
    @MainActor func testRefineDoesNotTriggerQuitConfirm() {
        let m = AppModel(engine: FakeEngine())
        m.history = []
        XCTAssertFalse(m.shouldConfirmQuit)
        m.refiningDictations.insert(UUID())
        XCTAssertTrue(m.isBusy)                  // still blocks concurrent jobs…
        XCTAssertFalse(m.shouldConfirmQuit)      // …but quitting is safe (text already saved)
        m.recordingStartedAt = Date()
        XCTAssertTrue(m.shouldConfirmQuit)       // an actual recording DOES warn
    }

    /// keepDictationAudio must attach the audio even when the full decode came back empty (the record exists
    /// with the streamed text either way).
    @MainActor func testRefineDictationKeepsAudioWhenDecodeEmpty() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "   ", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            m.keepDictationAudio = true
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.refineDictation(wav: wav, streamed: "стрим текст", id: UUID())

            XCTAssertEqual(m.history.first?.text, "стрим текст")   // streamed kept (empty decode)
            XCTAssertNotNil(m.history.first?.audioFile)            // audio kept anyway
        }
    }

    @MainActor func testDictationEmptyTextDropsRecord() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "   ", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.finishDictation(wav: wav)

            XCTAssertTrue(m.history.isEmpty)                        // blank dictation → no note inserted
            if case .idle = m.phase {} else { XCTFail("phase should be .idle") }
        }
    }

    @MainActor func testDictationBypassesWavConverter() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "ok", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            m.decoder = ClosureAudioDecoder(decode: { _ in throw AudioDecodingError.noDecoderAvailable })   // would fail if dictation used it
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.finishDictation(wav: wav)

            XCTAssertEqual(m.history.count, 1)                      // succeeded → the decoder was never called
            XCTAssertEqual(m.history.first?.text, "ok")
        }
    }

    @MainActor func testDictationSingleFlightGate() {
        let m = AppModel(engine: FakeEngine())
        m.history = []
        XCTAssertTrue(m.canDictate)            // idle → can start
        m.phase = .transcribing("x")
        XCTAssertFalse(m.canDictate)           // a job is running → blocked
        m.phase = .idle
        m.recordingStartedAt = Date()
        XCTAssertTrue(m.isRecordingDictation)
        XCTAssertTrue(m.isBusy)                // recording folds into isBusy (blocks drops/quick actions)
        XCTAssertFalse(m.canDictate)           // already recording → can't start another
    }

    /// While the mic-permission prompt is up, the lane is held (no drop/second-start races in) but the
    /// recording UI is NOT shown — capture (and its chip/timer/"Listening…") only begins after the grant.
    @MainActor func testRequestingMicHoldsLaneWithoutRecordingUI() {
        let m = AppModel(engine: FakeEngine())
        m.history = []
        XCTAssertTrue(m.canDictate)
        m.requestingMic = true
        XCTAssertTrue(m.isBusy)                  // permission check holds the lane…
        XCTAssertFalse(m.canDictate)             // …so nothing else can start
        XCTAssertFalse(m.isRecordingDictation)   // …but no "recording" UI yet (recordingStartedAt still nil)
        m.requestingMic = false
        XCTAssertFalse(m.isBusy)
    }

    @MainActor func testDictationFailureIsToastOnlyNotChip() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(throwOnTranscribe: true)
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.finishDictation(wav: wav)

            XCTAssertTrue(m.history.isEmpty)                 // failed dictation → nothing inserted
            // Toast-only: phase stays .idle (NOT .failed), so no stale "Try again" chip can replay an old drop.
            if case .idle = m.phase {} else { XCTFail("dictation failure should leave phase .idle, not .failed") }
        }
    }

    @MainActor func testDictationStopBeforeCaptureIsSilent() {
        let m = AppModel(engine: FakeEngine())
        m.history = []
        m.recordingStartedAt = Date()      // claimed, but the recorder isn't created yet (permission window)
        XCTAssertNil(m.recorder)
        m.stopAndTranscribeDictation()     // stop pressed pre-capture → silent cancel, no "empty" error
        XCTAssertNil(m.recordingStartedAt)
        XCTAssertFalse(m.isRecordingDictation)
        XCTAssertTrue(m.history.isEmpty)
        if case .idle = m.phase {} else { XCTFail("phase should stay .idle on a pre-capture cancel") }
    }

    @MainActor func testDictationPasteDisabledNeverPastes() async {
        await withTemporaryHistoryStoreAsync {
            var pasteCalls = 0
            var clipboard: String?
            let fake = FakeEngine(results: [EngineResult(text: "вставь меня", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = true
            m.dictationPasteIntoFrontmost = false
            m.attemptPaste = { pasteCalls += 1; return true }
            m.copyToClipboard = { clipboard = $0 }          // capture the seam (deterministic; no live system pasteboard)
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.finishDictation(wav: wav)

            XCTAssertEqual(pasteCalls, 0)                    // paste off → never synthesizes ⌘V
            XCTAssertEqual(m.history.first?.text, "вставь меня")
            XCTAssertEqual(clipboard, "вставь меня")         // text on the clipboard
        }
    }

    @MainActor func testDictationPasteEnabledAttemptsAndSetsClipboard() async {
        await withTemporaryHistoryStoreAsync {
            var pasteCalls = 0
            var clipboard: String?
            let fake = FakeEngine(results: [EngineResult(text: "наберись", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false                              // even with autoCopy off, paste must put text on the clipboard
            m.dictationPasteIntoFrontmost = true
            m.attemptPaste = { pasteCalls += 1; return true }   // simulate Accessibility-trusted + pasted
            m.copyToClipboard = { clipboard = $0 }          // capture the seam (deterministic; no live system pasteboard)
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.finishDictation(wav: wav)

            XCTAssertEqual(pasteCalls, 1)
            XCTAssertEqual(m.history.first?.text, "наберись")
            XCTAssertEqual(clipboard, "наберись")            // clipboard set for the ⌘V
        }
    }

    @MainActor func testDictationPasteUntrustedFallsBackToClipboard() async {
        await withTemporaryHistoryStoreAsync {
            var pasteCalls = 0
            var clipboard: String?
            let fake = FakeEngine(results: [EngineResult(text: "запас", language: "ru", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            m.dictationPasteIntoFrontmost = true
            m.attemptPaste = { pasteCalls += 1; return false }   // not Accessibility-trusted → no paste, graceful fallback
            m.copyToClipboard = { clipboard = $0 }          // capture the seam (deterministic; no live system pasteboard)
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.finishDictation(wav: wav)

            XCTAssertEqual(pasteCalls, 1)                    // attempted, returned false
            XCTAssertEqual(m.history.first?.text, "запас")   // record still saved
            XCTAssertEqual(clipboard, "запас")               // text remains on the clipboard
        }
    }

    func testDictationHotkeyRouting() {
        // Toggle mode: act on key-UP only.
        XCTAssertEqual(AppModel.dictationAction(for: .down, mode: .toggle), .ignore)
        XCTAssertEqual(AppModel.dictationAction(for: .up, mode: .toggle), .toggle)
        // Hold-to-talk: start on key-DOWN, stop on key-UP.
        XCTAssertEqual(AppModel.dictationAction(for: .down, mode: .hold), .start)
        XCTAssertEqual(AppModel.dictationAction(for: .up, mode: .hold), .stop)
    }

    func testDictationModeDefaultsToToggle() {
        XCTAssertEqual(DictationMode(rawValue: "") ?? .toggle, .toggle)
        XCTAssertEqual(DictationMode(rawValue: "hold"), .hold)
        XCTAssertEqual(DictationMode.allCases.count, 2)
    }


    // MARK: VAD silence detector

    func testSilenceDetectorArmsAfterSpeechThenStops() {
        var d = SilenceDetector(threshold: 0.01, silenceToStop: 1.0, minSpeechToArm: 0.5)
        XCTAssertFalse(d.feed(rms: 0.2, dt: 0.3))   // 0.3 s speech
        XCTAssertFalse(d.feed(rms: 0.2, dt: 0.3))   // 0.6 s speech → armed
        XCTAssertFalse(d.feed(rms: 0.0, dt: 0.5))   // 0.5 s silence
        XCTAssertTrue(d.feed(rms: 0.0, dt: 0.5))    // 1.0 s silence → stop
    }

    func testSilenceDetectorNeverStopsBeforeSpeech() {
        var d = SilenceDetector(threshold: 0.01, silenceToStop: 0.5, minSpeechToArm: 0.4)
        for _ in 0..<10 { XCTAssertFalse(d.feed(rms: 0.0, dt: 0.5)) }   // pure silence → never arms
    }

    func testSilenceDetectorResetsSilenceOnRenewedSpeech() {
        var d = SilenceDetector(threshold: 0.01, silenceToStop: 1.0, minSpeechToArm: 0.2)
        XCTAssertFalse(d.feed(rms: 0.5, dt: 0.3))   // armed
        XCTAssertFalse(d.feed(rms: 0.0, dt: 0.6))   // 0.6 s silence
        XCTAssertFalse(d.feed(rms: 0.5, dt: 0.1))   // speech resets the silence run
        XCTAssertFalse(d.feed(rms: 0.0, dt: 0.6))   // 0.6 s again (not 1.2)
        XCTAssertTrue(d.feed(rms: 0.0, dt: 0.5))    // 1.1 s ≥ 1.0 → stop
    }

    func testSilenceDetectorIgnoresNonPositiveDt() {
        var d = SilenceDetector(threshold: 0.01, silenceToStop: 0.1, minSpeechToArm: 0.0)
        XCTAssertFalse(d.feed(rms: 0.0, dt: 0))     // dt <= 0 → no-op
    }


}
