import XCTest
import os
import AVFoundation
import AppKit
@testable import ParlaCore
@testable import Parla

/// The pipeline: decode routing, queueing, cancel, re-transcribe, the lane handle, playback rendition, and progress-phase correctness.
final class TranscriptionFlowTests: ParlaLogicTestCase {
    // MARK: Native decode routing (Phase 2c regression)

    /// The Opus lane must be chosen by CONTENT (Ogg magic "OggS"), not only by extension — Telegram voice
    /// messages are often saved with no extension, and routing them to the AVAssetReader lane (which can't demux
    /// Ogg) is exactly the "No audio decoder available" regression this fixes.
    func testOpusDecoderRoutesOggByContentNotJustExtension() throws {
        let tmp = FileManager.default.temporaryDirectory
        let oggNoExt = tmp.appendingPathComponent("voice_\(UUID().uuidString)")   // no extension, Ogg content
        try Data("OggS\u{01}\u{00}\u{00}\u{00}".utf8).write(to: oggNoExt)
        defer { try? FileManager.default.removeItem(at: oggNoExt) }
        XCTAssertTrue(OpusAudioDecoder.looksLikeOgg(oggNoExt), "an extension-less OggS file must route to the Opus lane")

        let byExt = tmp.appendingPathComponent("x.ogg")                            // extension wins even w/o content
        try Data("whatever".utf8).write(to: byExt)
        defer { try? FileManager.default.removeItem(at: byExt) }
        XCTAssertTrue(OpusAudioDecoder.looksLikeOgg(byExt))

        let notOgg = tmp.appendingPathComponent("clip_\(UUID().uuidString)")        // WAV-ish header, no ogg ext → Lane 2
        try Data("RIFF....WAVE".utf8).write(to: notOgg)
        defer { try? FileManager.default.removeItem(at: notOgg) }
        XCTAssertFalse(OpusAudioDecoder.looksLikeOgg(notOgg))

        XCTAssertFalse(OpusAudioDecoder.looksLikeOgg(tmp.appendingPathComponent("missing-\(UUID().uuidString)")))
    }

    /// Runtime proof that the libopusfile lane REALLY decodes an Ogg/Opus file — on every machine and in CI.
    /// This used to be opt-in behind `PARLA_OGG_FIXTURE`, which meant the native decoder (the whole point of
    /// Phase 2c — no ffmpeg) was automatically proven NOWHERE. `Fixtures/tone.ogg` is a 6.7 KB synthetic tone
    /// (no voice → fine in a public repo), so the real C decode path runs unconditionally.
    func testDecodesBundledOggFixture() throws {
        let f = try XCTUnwrap(Bundle.module.url(forResource: "tone", withExtension: "ogg", subdirectory: "Fixtures"),
                              "bundled Ogg fixture missing — check Package.swift resources")
        try assertOggDecodes(f, expectedSeconds: 3.0)
    }

    /// The intake rule from `0b779fc`: a Telegram voice note arrives with NO extension, so recognition must be by
    /// CONTENT. Same bytes, no extension → still sniffed as Ogg, still accepted by the one intake gate, still
    /// measurable by the cheap index probe (so it can't slip the free/Pro length gate).
    func testExtensionlessOggIsSniffedAndAcceptedByIntake() throws {
        let src = try XCTUnwrap(Bundle.module.url(forResource: "tone", withExtension: "ogg", subdirectory: "Fixtures"))
        let bare = FileManager.default.temporaryDirectory.appendingPathComponent("voice_\(UUID().uuidString)")
        try FileManager.default.copyItem(at: src, to: bare)
        defer { try? FileManager.default.removeItem(at: bare) }

        XCTAssertTrue(OpusAudioDecoder.looksLikeOgg(bare), "no extension → must be recognized by the OggS header")
        XCTAssertTrue(AppModel.isTranscribable(bare), "the intake gate must accept an extension-less Ogg voice note")
        try assertOggDecodes(bare, expectedSeconds: 3.0)
    }

    /// Optional extra: point PARLA_OGG_FIXTURE at a REAL voice note to run the same assertions on real bytes.
    /// (Real voice never lives in git; the bundled tone is what CI proves.)
    func testDecodeRealOggFixtureIfProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["PARLA_OGG_FIXTURE"] else {
            throw XCTSkip("PARLA_OGG_FIXTURE not set — the bundled fixture already covers the decode path")
        }
        let f = URL(fileURLWithPath: path)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: f.path), "fixture missing")
        try assertOggDecodes(f, expectedSeconds: nil)
    }

    /// Shared body: the cheap index-based duration probe (what the length gate uses) must agree with a real full
    /// decode, and the decode must produce a non-trivial 16 kHz WAV.
    private func assertOggDecodes(_ f: URL, expectedSeconds: Double?, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(OpusAudioDecoder.looksLikeOgg(f), "should be recognized as Ogg", file: file, line: line)
        let probe = try XCTUnwrap(OpusAudioDecoder.oggDurationSeconds(f),
                                  "opusfile op_pcm_total should measure the ogg WITHOUT decoding", file: file, line: line)
        let wav = try OpusAudioDecoder().decodeToWav16k(f)
        defer { try? FileManager.default.removeItem(at: wav) }
        let dur = AudioDuration.seconds(ofFileAt: wav.path) ?? 0
        XCTAssertGreaterThan(dur, 1, "opusfile should decode to a non-trivial WAV", file: file, line: line)
        XCTAssertEqual(probe, dur, accuracy: 0.2, "index-probe duration ≈ decoded duration", file: file, line: line)
        if let expected = expectedSeconds {
            XCTAssertEqual(dur, expected, accuracy: 0.2, "decoded duration should match the fixture", file: file, line: line)
        }
    }

    /// Tip-jar consumables are separate from Pro (a tip must never grant the entitlement) and stay in the
    /// placeholder namespace pre-rebrand.
    func testTipProductsSeparateFromPro() {
        XCTAssertEqual(ProGate.tipProductIDs.count, 3)
        XCTAssertFalse(ProGate.tipProductIDs.contains(ProGate.proProductID), "a tip must never be the Pro product")
        for id in ProGate.tipProductIDs {
            XCTAssertTrue(id.hasPrefix("com.parla.tip."), "tip IDs stay in the placeholder namespace")
        }
    }

    /// The export split: TXT/Markdown are free, SRT/VTT/JSON are Pro.
    func testProExportFormatSplit() {
        XCTAssertFalse(ProGate.isProExportFormat(.txt))
        XCTAssertFalse(ProGate.isProExportFormat(.markdown))
        XCTAssertTrue(ProGate.isProExportFormat(.srt))
        XCTAssertTrue(ProGate.isProExportFormat(.vtt))
        XCTAssertTrue(ProGate.isProExportFormat(.json))
    }

    /// The iOS app resolves its packages through the generated Xcode project, NOT through the root package —
    /// proven by experiment: seeding a different version into the project's resolved file made xcodebuild check
    /// that version out. With no file seeded, the whole iOS graph resolves fresh from open-ended ranges on every
    /// clean machine, so the day WhisperKit tags 0.19 the iOS job silently builds against a different WhisperKit
    /// than the macOS jobs, from the same commit. `apps/ios/Package.resolved` is that seed (Xcode never writes
    /// one here, so it is maintained by hand from the root file), and this keeps the pair from drifting apart
    /// silently — a stale seed is worse than none, because it looks pinned.
    func testTheIOSDependencySeedMatchesTheRootResolve() throws {
        func pins(_ path: String) throws -> [String: String] {
            let data = try Data(contentsOf: repoRoot.appendingPathComponent(path))
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let list = json?["pins"] as? [[String: Any]] ?? []
            return Dictionary(uniqueKeysWithValues: list.compactMap { pin -> (String, String)? in
                guard let id = pin["identity"] as? String,
                      let state = pin["state"] as? [String: Any],
                      let revision = state["revision"] as? String else { return nil }
                return (id, revision)
            })
        }
        let root = try pins("Package.resolved")
        let ios  = try pins("apps/ios/Package.resolved")
        XCTAssertGreaterThan(root.count, 5, "the root resolve looks empty/unreadable")
        XCTAssertEqual(root, ios,
                       "apps/ios/Package.resolved has drifted from the root resolve. Bumping a requirement means "
                       + "refreshing BOTH in the same commit: cd apps/ios && xcodegen generate && cp "
                       + "../../Package.resolved Package.resolved, then re-resolve to confirm it still applies.")
    }


    // MARK: Audio-cache prune protection — TOCTOU

    /// Pins the exact bug the review found: the displayed/playing entry is never evicted, and the
    /// re-check is a pure function applied after the off-main pass.
    func testApplyProtectionRemovesShownId() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertEqual(AudioStore.applyProtection([a, b, c], evicting: b), [a, c])       // shown id dropped
        XCTAssertEqual(AudioStore.applyProtection([a, b, c], evicting: nil), [a, b, c])  // nil → passthrough
        XCTAssertEqual(AudioStore.applyProtection([a, b], evicting: c), [a, b])          // not in plan → unchanged
        XCTAssertEqual(AudioStore.applyProtection([], evicting: a), [])                  // empty plan
        // Invariant: whatever the plan, the protected id is never in the result.
        XCTAssertFalse(AudioStore.applyProtection([a, b, c], evicting: b).contains(b))
    }


    // MARK: Transcribe orchestration with a fake engine

    @MainActor func testTranscribeSingleFileInsertsHistory() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "привет мир", language: "ru", segments: [], duration: 1.5)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }   // don't touch the notification center in tests
            m.soundOnComplete = false          // no completion beeps during tests
            m.history = []                     // ignore any legacy Murmur history migrated on the dev machine
            m.autoCopy = false
            // src is .m4a → AVFoundation path: the ffmpeg converter is intentionally NOT involved.
            // No stub on purpose — if a regression routed .m4a through ffmpeg, the real converter would
            // hit this fake 5-byte file and FAIL the test. The converter path is covered by testTranscribeUsesConverterForOpus.
            let src = makeTempSource()
            defer { try? FileManager.default.removeItem(at: src) }

            await m.transcribe(urls: [src])

            XCTAssertEqual(m.history.count, 1)
            XCTAssertEqual(m.history.first?.text, "привет мир")
            XCTAssertEqual(m.history.first?.language, "ru")
            XCTAssertEqual(m.selection, m.history.first?.id)
            if case .idle = m.phase {} else { XCTFail("phase should be .idle") }
            XCTAssertEqual(fake.ensureLoadedCalls, 1)
            XCTAssertEqual(fake.transcribeCalls, 1)
            XCTAssertNotNil(m.history.first?.audioFile)   // keepAudio copied the source AFTER the insert (perf-fix path)
        }
    }


    // MARK: Transcription queue (stack drops instead of dropping them)

    @MainActor func testDropWhileBusyQueuesInsteadOfRejecting() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine()
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.phase = .transcribing("busy")          // lane occupied → a drop must QUEUE, not run and not vanish
            let src = makeTempSource()
            defer { try? FileManager.default.removeItem(at: src) }

            m.handleDrop(urls: [src])
            XCTAssertEqual(m.transcriptionQueue.count, 1)   // queued (the old guard silently dropped it)
            XCTAssertEqual(fake.transcribeCalls, 0)         // and NOT started while the lane is busy

            m.handleDrop(urls: [src])
            XCTAssertEqual(m.transcriptionQueue.count, 2)   // a second drop stacks behind the first
            XCTAssertEqual(m.queuedCount, 2)                // watchQueue empty → total == manual
        }
    }

    @MainActor func testDrainManualQueueBailsWhileBusyDequeuesWhenFree() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "x", language: "en", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            let src = makeTempSource()
            defer { try? FileManager.default.removeItem(at: src) }
            m.transcriptionQueue = [TranscriptionJob(urls: [src])]

            m.phase = .transcribing("busy")
            m.drainManualQueue()                             // busy → must not dequeue or start
            XCTAssertEqual(m.transcriptionQueue.count, 1)
            XCTAssertEqual(fake.transcribeCalls, 0)

            m.phase = .idle
            m.drainManualQueue()                             // free → synchronous dequeue + phase claim (the Task runs async)
            XCTAssertEqual(m.transcriptionQueue.count, 0)
            if case .preparing = m.phase {} else { XCTFail("drain should claim the lane synchronously") }
        }
    }


    // MARK: Transcription cancel (stop + discard the in-flight result)

    @MainActor func testCancelTranscriptionClearsQueue() async {
        await withTemporaryHistoryStoreAsync {
            let m = AppModel(engine: FakeEngine())
            m.history = []
            m.transcriptionQueue = [TranscriptionJob(urls: [makeTempSource()]),
                                    TranscriptionJob(urls: [makeTempSource()])]
            m.cancelTranscription()                          // no running task → just clears what's queued
            XCTAssertTrue(m.transcriptionQueue.isEmpty)
            XCTAssertFalse(m.cancelling)                     // nothing in flight → nothing to "stop"
        }
    }

    @MainActor func testCancelledRunDiscardsResultAndEndsIdle() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "should-not-save", language: "en", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            let src = makeTempSource()
            defer { try? FileManager.default.removeItem(at: src) }

            let task = Task { @MainActor in await m.transcribe(urls: [src]) }
            task.cancel()                                    // cancelled → the loop's Task.isCancelled guard trips
            await task.value

            XCTAssertTrue(m.history.isEmpty)                 // nothing partial saved
            XCTAssertEqual(fake.transcribeCalls, 0)          // never decoded (cancelled at the loop top)
            XCTAssertFalse(m.cancelling)
            if case .idle = m.phase {} else { XCTFail("a cancelled run ends idle") }
        }
    }

    @MainActor func testCancelMidBatchKeepsCompletedDiscardsInFlight() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [
                EngineResult(text: "file-A-kept", language: "en", segments: [], duration: 1),
                EngineResult(text: "file-B-discarded", language: "en", segments: [], duration: 1),
            ])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.autoCopy = false
            m.history = []
            let a = makeTempSource("a.m4a"), b = makeTempSource("b.m4a")
            defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }

            // Cancel DURING file B's decode → file A is already inserted (kept), B's decoded result is discarded.
            let box = TaskBox()
            fake.onTranscribe = { call in if call == 2 { box.task?.cancel() } }
            let task = Task { @MainActor in await m.transcribe(urls: [a, b]) }
            box.task = task
            await task.value

            XCTAssertEqual(m.history.count, 1)                    // file A completed → KEPT
            XCTAssertEqual(m.history.first?.text, "file-A-kept")
            XCTAssertEqual(fake.transcribeCalls, 2)               // file B decoded, but its result was DISCARDED (not saved)
            XCTAssertFalse(m.cancelling)                          // flag cleared on the cancelled exit
            if case .idle = m.phase {} else { XCTFail("a cancelled run ends idle") }
        }
    }

    @MainActor func testCancelRetranscribeKeepsOldTranscript() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "NEW-should-not-apply", language: "en", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.autoCopy = false
            let src = makeTempSource("orig.m4a")
            defer { try? FileManager.default.removeItem(at: src) }
            let item = TranscriptItem(sourceName: "orig.m4a", language: "en", durationSec: 1,
                                      model: "old-model", text: "OLD-keep-me", segments: [], sourcePath: src.path)
            m.history = [item]

            // Cancel DURING the re-transcribe decode → the in-place replace must be skipped (old transcript kept).
            let box = TaskBox()
            fake.onTranscribe = { _ in box.task?.cancel() }
            m.retranscribe(item, with: "new-model")
            let t = m.currentTranscriptionTask
            box.task = t
            await t?.value

            XCTAssertEqual(m.history.first?.text, "OLD-keep-me")   // untouched
            XCTAssertEqual(m.history.first?.model, "old-model")    // not replaced with the new model
            XCTAssertFalse(m.cancelling)
            if case .idle = m.phase {} else { XCTFail("a cancelled re-transcribe ends idle") }
        }
    }


    // MARK: Dictation orchestration

    @MainActor func testDictationInsertsHistoryRecord() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "надиктованный текст", language: "ru", segments: [], duration: 2)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            // 5-byte stub .wav → AudioDuration.seconds is nil → the short-clip guard is skipped and the
            // FakeEngine runs. The live mic capture itself is manual-only; this drives the result back-half.
            let wav = makeTempSource("d.wav")
            defer { try? FileManager.default.removeItem(at: wav) }

            await m.finishDictation(wav: wav)

            XCTAssertEqual(m.history.count, 1)
            XCTAssertEqual(m.history.first?.text, "надиктованный текст")
            XCTAssertNil(m.history.first?.sourcePath)               // dictation → no re-transcribable source
            XCTAssertFalse(m.canRetranscribe(m.history.first!))     // → re-transcribe stays disabled
            XCTAssertEqual(fake.transcribeCalls, 1)
            if case .idle = m.phase {} else { XCTFail("phase should be .idle") }
        }
    }


    // MARK: AVFoundation-direct decode path (BUNDLE_FFMPEG P0)

    func testAvDecodableMirrorsDirectlyPlayable() {
        // v1 is the exact mirror of the prod-proven playback set — keep them in lock-step.
        XCTAssertEqual(AppModel.avDecodable, AudioStore.directlyPlayable)
    }

    func testAvDecodableIsSubsetOfAudioExts() {
        XCTAssertTrue(AppModel.avDecodable.isSubset(of: AppModel.audioExts))
    }

    func testAvDecodableExcludesDecoderOnlyFormats() {
        for ext in ["ogg", "oga", "opus", "3gp", "flac"] {
            XCTAssertFalse(AppModel.avDecodable.contains(ext), "\(ext) must route through the decoder")
        }
    }

    /// `AudioDuration` (the AVFoundation probe the engine + chunking gate use) must return
    /// nil for a path AVAudioFile can't open, so callers fall back instead of trusting a bogus length.
    func testAudioDurationNilForNonAudio() {
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("parla-not-audio-\(UUID().uuidString).bin")
        try? Data([0x00, 0x01, 0x02, 0x03, 0x04]).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        XCTAssertNil(AudioDuration.seconds(ofFileAt: junk.path))
        XCTAssertNil(AudioDuration.seconds(ofFileAt: "/no/such/file.wav"))
    }

    /// An AVFoundation format (.m4a) must NOT hit the decoder — the source path goes straight to the engine.
    @MainActor func testTranscribeSkipsConverterForAvFormat() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "ok", language: "en", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            // If the converter ran, the engine would receive THIS sentinel instead of the source path.
            m.decoder = ClosureAudioDecoder(decode: { _ in URL(fileURLWithPath: "/tmp/CONVERTER-RAN.wav") })
            let src = makeTempSource("voice.m4a")
            defer { try? FileManager.default.removeItem(at: src) }

            await m.transcribe(urls: [src])

            XCTAssertEqual(fake.transcribedPaths.first, src.path)                      // original handed straight to the engine
            XCTAssertFalse(fake.transcribedPaths.contains("/tmp/CONVERTER-RAN.wav"))   // the decoder never ran
        }
    }

    /// A non-AVFoundation format (.opus) must still go through the native decoder.
    @MainActor func testTranscribeUsesConverterForOpus() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "ok", language: "en", segments: [], duration: 1)])
            let m = AppModel(engine: fake)
            m.postNotification = { _, _ in }
            m.soundOnComplete = false
            m.history = []
            m.autoCopy = false
            m.decoder = ClosureAudioDecoder(decode: { _ in URL(fileURLWithPath: "/tmp/fake.wav") })
            let src = makeTempSource("voice.opus")   // .opus ∉ avDecodable → must route through the decoder
            defer { try? FileManager.default.removeItem(at: src) }

            await m.transcribe(urls: [src])

            XCTAssertEqual(fake.transcribedPaths.first, "/tmp/fake.wav")   // engine got the converted WAV
        }
    }


    // MARK: A fresh transcript must be visible even when a search is active

    /// selectedItem is scoped to filteredHistory and falls back to its FIRST element, so transcribing while a
    /// query is active left the new note filtered out and the pane showing an unrelated older one. The deep-link
    /// and Related-navigation paths already clear the query first; the insert path did not. It also mattered
    /// beyond visibility: activeLanguageSuggestion gates on `selection`, not on what is displayed, so the
    /// nudge's «switch and re-transcribe» rendered above the wrong note and acted on the hidden one.
    @MainActor func testTranscribingWhileASearchIsActiveStillShowsTheNewNote() async {
        await withTemporaryHistoryStoreAsync {
            let fake = FakeEngine(results: [EngineResult(text: "совершенно другой текст", language: "ru",
                                                         segments: [], duration: 1)])
            let m = AppModel(engine: fake, ai: NoopAIService(), embedder: FakeEmbedder())
            m.postNotification = { _, _ in }; m.soundOnComplete = false
            m.isProUser = { true }; m.mediaDuration = { _ in 1 }
            m.history = [self.makeItem(name: "old.m4a", text: "старая заметка про бухгалтерию", lang: "ru")]
            m.searchQuery = "бухгалтерию"          // the old note matches; the new one will not

            await m.transcribe(urls: [URL(fileURLWithPath: "/tmp/parla-new.m4a")])

            XCTAssertEqual(m.history.count, 2, "precondition: the transcript was saved")
            XCTAssertEqual(m.selectedItem?.id, m.history.first?.id,
                           "the pane shows the note that was just transcribed, not an older search hit")
            XCTAssertEqual(m.searchQuery, "", "the stale query is cleared, as on the deep-link path")
        }
    }


    // MARK: The transcription lane handle — a finishing job must not disown a running one

    /// A job's continuation runs AFTER the lane is released: `phase` goes .idle before the tail work (the
    /// completion notification, the audio prune, and on the re-transcribe path a whole refreshSemanticIndex,
    /// which is minutes with MLX). A new job legitimately starts in that window — and the finishing job then
    /// cleared `currentTranscriptionTask` unconditionally, destroying the NEW job's handle. Both Cancel buttons
    /// (MainPane and the iOS chip) render only while that handle is non-nil, so the running transcription became
    /// uncancellable and its queue unpurgeable.
    ///
    /// Simulated at the state level: the token is what the continuations test, and this pins that a stale owner
    /// cannot clear a newer owner's handle.
    @MainActor func testAFinishingJobDoesNotClearANewerJobsCancelHandle() {
        let m = AppModel(engine: FakeEngine(), ai: NoopAIService(), embedder: FakeEmbedder())

        m.transcriptionLaneToken += 1
        let staleToken = m.transcriptionLaneToken          // job A takes the lane
        m.currentTranscriptionTask = Task { }

        m.transcriptionLaneToken += 1                       // job B takes it during A's tail
        let liveHandle = Task<Void, Never> { }
        m.currentTranscriptionTask = liveHandle

        // A's continuation finally runs.
        if m.transcriptionLaneToken == staleToken { m.currentTranscriptionTask = nil }

        XCTAssertNotNil(m.currentTranscriptionTask, "the running job keeps its Cancel handle")
        liveHandle.cancel()
    }

    /// …and the owner must still clear its own handle, or Cancel would linger forever after a job ends.
    @MainActor func testAJobStillClearsItsOwnHandle() {
        let m = AppModel(engine: FakeEngine(), ai: NoopAIService(), embedder: FakeEmbedder())
        m.transcriptionLaneToken += 1
        let token = m.transcriptionLaneToken
        m.currentTranscriptionTask = Task { }
        m.cancelling = true

        if m.transcriptionLaneToken == token { m.currentTranscriptionTask = nil; m.cancelling = false }

        XCTAssertNil(m.currentTranscriptionTask)
        XCTAssertFalse(m.cancelling)
    }


    // MARK: Playback rendition — ask the player, do not guess from the extension

    /// Live report from the owner: importing a 71-minute .mp4 re-encoded a playback copy for **39 minutes**,
    /// concurrently with transcribing the same file, competing for CPU the whole way — while `AVAudioPlayer`
    /// opens that exact .mp4 directly. `directlyPlayable` simply omitted mp4/mov/m4v, so every video import paid
    /// for work it did not need, on the long-audio path Pro is sold for.
    func testAContainerThePlayerCanOpenNeedsNoRendition() throws {
        // Written as .m4a (what AVAudioFile emits) and then given the .mp4 extension — the SAME container, and
        // the exact case that used to be re-encoded. Testing this with a .m4a would prove nothing: .m4a is on the
        // fast-accept list, so the probe would never run.
        let tmp = FileManager.default.temporaryDirectory
        let written = tmp.appendingPathComponent("probe-\(UUID().uuidString).m4a")
        let src = tmp.appendingPathComponent("probe-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: written); try? FileManager.default.removeItem(at: src) }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        // Scoped so the AVAudioFile DEALLOCS before we touch the bytes — it finalises the container on deinit,
        // and this codebase has been caught by that before (the AAC rendition validated a half-written file).
        do {
            let file = try AVAudioFile(forWriting: written, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
            ])
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44100)!
            buf.frameLength = 44100
            for i in 0..<Int(buf.frameLength) { buf.floatChannelData![0][i] = sin(Float(i) * 0.01) * 0.2 }
            try file.write(from: buf)
        }
        try FileManager.default.moveItem(at: written, to: src)

        XCTAssertFalse(AudioStore.directlyPlayable.contains("mp4"), "precondition: mp4 is NOT fast-accepted")
        XCTAssertTrue(AudioStore.canPlayDirectly(src),
                      "the player opens this .mp4 — rendering a playback copy would be pure waste")
    }

    /// …and something the player cannot open must still be rendered, or the note ships without a player.
    func testAContainerThePlayerCannotOpenStillNeedsARendition() throws {
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: junk) }
        try Data(repeating: 7, count: 4096).write(to: junk)
        XCTAssertFalse(AudioStore.canPlayDirectly(junk))
    }

    /// The fast-accept list must stay a shortcut that only ever says YES — never a veto.
    func testTheExtensionListIsAFastAcceptNotAGate() {
        for ext in AudioStore.directlyPlayable {
            XCTAssertTrue(AudioStore.canPlayDirectly(URL(fileURLWithPath: "/nonexistent/x.\(ext)")),
                          ".\(ext) is on the fast-accept list, so it must not be probed at all")
        }
        // …and a container that is NOT on the list is decided by the probe, not rejected outright.
        XCTAssertFalse(AudioStore.directlyPlayable.contains("mp4"), "precondition: mp4 was never on the list")
    }


    // MARK: A stale model-load event must not put "Loading the model…" back over live progress

    /// Live report from the owner: a 1-hour video sat on "Loading the model into memory…" while it was in fact
    /// transcribing — the chunk split had finished 20 minutes earlier (36 chunks in 31 s, from the temp-dir
    /// timestamps). `progressHandler` writes `phase` from an unstructured `Task`, which has no ordering against
    /// the chunk loop, so WhisperKit's start-of-load `.loading` event landed AFTER "Transcribing 1/36" and
    /// replaced it. On a 36-chunk file that is minutes of an app that looks frozen while it is working.
    @MainActor func testAStaleModelLoadEventDoesNotOverwriteTranscribingProgress() async {
        let m = AppModel(engine: FakeEngine(), ai: NoopAIService(), embedder: FakeEmbedder())
        m.phase = .transcribing("chunk 1 of 36", batch: BatchProgress(index: 1, total: 36, done: 0))

        m.progressHandler()(.loading)                      // the late event
        m.progressHandler()(.downloading(0.5))

        // DRAIN the handler's unstructured Task before asserting. Without this the test passes with the guard
        // deleted — it would be asserting before the overwrite it exists to catch could even happen. (Caught by
        // revert-checking this very test: it stayed green with the fix removed.)
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(m.phaseAcceptsModelLoadUpdate, "while transcribing, a model-load event is stale news")
        guard case .transcribing = m.phase else {
            return XCTFail("live progress was overwritten by a stale model-load event: \(m.phase)")
        }
    }

    /// …but a load event must still be shown when the pipeline really is loading, or the user gets a blank wait.
    @MainActor func testAModelLoadEventIsShownWhileTheModelIsActuallyLoading() {
        let m = AppModel(engine: FakeEngine(), ai: NoopAIService(), embedder: FakeEmbedder())
        for start in [EnginePhase.idle, .preparing("f.m4a"), .loadingModel] {
            m.phase = start
            XCTAssertTrue(m.phaseAcceptsModelLoadUpdate, "\(start) must still accept load progress")
        }
    }


    // MARK: Hold-to-talk — a key-up during the mic prompt must not be swallowed

    /// First hold-to-talk use: startDictation suspends on the system mic-permission prompt, so
    /// `recordingStartedAt` — and therefore `isRecordingDictation` — is still nil. The user has to LET GO of the
    /// hotkey to click Allow, and that key-up hit `guard isRecordingDictation else { return }` and vanished. The
    /// suspended start then committed the recorder anyway: the mic went live with nothing held and recorded until
    /// the 120 s cap. A live microphone the user believes is off.
    @MainActor func testAStopDuringTheMicPromptIsRememberedNotDropped() {
        let m = AppModel(engine: FakeEngine(), ai: NoopAIService(), embedder: FakeEmbedder())
        m.requestingMic = true          // the prompt is up; startDictation is suspended on ensureMicAccess()
        XCTAssertFalse(m.isRecordingDictation, "precondition: capture has NOT begun yet")

        m.stopAndTranscribeDictation()  // the user releases the key to click Allow

        XCTAssertTrue(m.dictationStopRequested,
                      "the key-up must be recorded so the resuming start abandons instead of opening the mic")
    }

    /// …and it must stay a no-op when nothing is pending, or an idle stop would poison the NEXT dictation.
    @MainActor func testAStopWhenNothingIsPendingChangesNothing() {
        let m = AppModel(engine: FakeEngine(), ai: NoopAIService(), embedder: FakeEmbedder())
        m.stopAndTranscribeDictation()
        XCTAssertFalse(m.dictationStopRequested)
        XCTAssertFalse(m.requestingMic)
    }


    // MARK: Re-transcribe (feature 01)

    /// Key backward compat: an old history.json without sourcePath/sourceBookmark decodes.
    func testCodableBackwardCompatSourceFields() throws {
        let legacy = #"[{"id":"\#(UUID().uuidString)","date":740000000,"sourceName":"a.ogg","language":"ru","durationSec":1,"model":"openai_whisper-tiny","text":"привет","segments":[]}]"#
        let items = try JSONDecoder().decode([TranscriptItem].self, from: Data(legacy.utf8))
        XCTAssertNil(items.first?.sourcePath)        // missing key → nil, NOT a throw
        XCTAssertNil(items.first?.sourceBookmark)
        XCTAssertFalse(items.first?.hasResolvableSource ?? true)
    }

    func testCodableRoundtripWithSource() throws {
        var item = makeItem(text: "txt")
        item.sourcePath = "/tmp/x.ogg"
        item.sourceBookmark = Data([1, 2, 3])
        let data = try JSONEncoder().encode([item])
        let back = try JSONDecoder().decode([TranscriptItem].self, from: data)
        XCTAssertEqual(back.first?.sourcePath, "/tmp/x.ogg")
        XCTAssertEqual(back.first?.sourceBookmark, Data([1, 2, 3]))
    }

    func testResolveSourceFoundByPath() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ogg")
        try Data("x".utf8).write(to: tmp)
        defer { try? fm.removeItem(at: tmp) }
        var item = makeItem(text: "t")
        item.sourcePath = tmp.path
        XCTAssertEqual(item.resolveSource(), .found(URL(fileURLWithPath: tmp.path), scoped: false))
        XCTAssertTrue(item.hasResolvableSource)
    }

    func testResolveSourceMissingWhenPathGone() {
        var item = makeItem(text: "t")
        item.sourcePath = "/nope/\(UUID().uuidString).ogg"
        XCTAssertEqual(item.resolveSource(), .missing)
        XCTAssertFalse(item.hasResolvableSource)
    }

    func testResolveSourceMissingWhenNilPath() {
        let item = makeItem(text: "t")   // sourcePath == nil (as in a legacy entry)
        XCTAssertEqual(item.resolveSource(), .missing)
        XCTAssertFalse(item.hasResolvableSource)
    }

    func testMakeAndResolveBookmarkFallback() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ogg")
        try Data("x".utf8).write(to: tmp)
        defer { try? fm.removeItem(at: tmp) }
        let bm = makeSourceBookmark(tmp)
        XCTAssertNotNil(bm)
        var item = makeItem(text: "t")
        item.sourcePath = nil            // path absent — should be found via bookmark
        item.sourceBookmark = bm
        if case .found(let url, _) = item.resolveSource() {
            XCTAssertTrue(fm.fileExists(atPath: url.path))
            XCTAssertEqual(url.lastPathComponent, tmp.lastPathComponent)
        } else {
            XCTFail("должен найтись по bookmark")
        }
    }

    @MainActor func testRetranscribeSameModelIsNoop() {
        withTemporaryHistoryStore {
            let m = AppModel()
            var item = makeItem(text: "оригинал", model: "openai_whisper-tiny")
            item.sourcePath = "/tmp/whatever.ogg"
            m.history = [item]
            m.retranscribe(item, with: "openai_whisper-tiny")   // same model → no-op, neither history nor phase
            XCTAssertEqual(m.history.first?.text, "оригинал")
            if case .idle = m.phase {} else { XCTFail("phase должна остаться .idle") }
        }
    }

    @MainActor func testRetranscribeClearsLastAttemptedSoChipWontReplayOldDrop() {
        withTemporaryHistoryStore {
            let m = AppModel(engine: FakeEngine())
            m.lastAttemptedURLs = [URL(fileURLWithPath: "/tmp/old-drop.ogg")]   // a prior manual drop
            XCTAssertTrue(m.canRetryLast)
            var item = makeItem(text: "orig", model: "openai_whisper-tiny")
            item.sourcePath = "/tmp/missing-\(UUID().uuidString).ogg"           // re-transcribe will fail to resolve
            m.history = [item]
            m.retranscribe(item, with: "openai_whisper-base")                   // different model → proceeds + clears
            XCTAssertTrue(m.lastAttemptedURLs.isEmpty)                          // chip's «Try again» can't replay the old drop
        }
    }

    @MainActor func testCanRetranscribe() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ogg")
        try Data("x".utf8).write(to: tmp)
        defer { try? fm.removeItem(at: tmp) }
        let m = AppModel()
        XCTAssertFalse(m.canRetranscribe(makeItem(text: "t")))   // no sourcePath → not allowed
        var present = makeItem(text: "t")
        present.sourcePath = tmp.path
        XCTAssertTrue(m.canRetranscribe(present))                // engine free + file present
    }


}
