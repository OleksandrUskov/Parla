import Foundation
import os
// AVFAudio's AVAudioConverterInputBlock is @Sendable but is called synchronously on the audio thread
// (no real concurrency) — @preconcurrency relaxes the spurious Sendable-capture diagnostics for AVFAudio
// types (e.g. the `AVAudioPCMBuffer` we feed it), mirroring the `@preconcurrency import WhisperKit` seam
// in TranscriptionEngine. No `@unchecked Sendable` needed.
@preconcurrency import AVFoundation

/// Records the microphone straight to a **16 kHz mono Int16 WAV** — WhisperKit's native input format, so a
/// dictation result needs NO ffmpeg decode: the WAV goes straight to `engine.transcribe(wavPath:)` (`.wav`
/// is in `AppModel.avDecodable`, so the dictation path bypasses the `decoder` seam entirely).
///
/// Concurrency (we're on Swift 6 `.v6`): the input tap fires on CoreAudio's real-time thread. All capture
/// state (the `AVAudioConverter` + `AVAudioFile`) is owned by a private `WavSink` that is *transferred* into
/// the tap block and touched ONLY from that thread — it never crosses back to the main actor. The engine
/// lifecycle (install/remove tap, start/stop) stays on `@MainActor`; only the final WAV `URL` (a `Sendable`
/// value) is returned to the caller. Teardown is deterministic (`removeTap` + `engine.stop()` in `stop()`),
/// never in `deinit` (mirrors the `FolderWatcher` / `PlaybackController` no-`@MainActor`-deinit discipline).
@MainActor
public final class MicRecorder {
    /// WhisperKit's native input: 16 kHz mono Int16 PCM. Recording straight to this skips the whole
    /// ffmpeg / `AudioConverter` decode step for dictation. Pinned by a unit test (`targetFormat` constant).
    public static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 16_000, channels: 1, interleaved: true)!

    /// Auto-stop a forgotten session so a stuck recording can't grow unbounded. `<= 0` disables it.
    public let maxSeconds: TimeInterval

    private let engine = AVAudioEngine()
    private var outputURL: URL?
    private var autoStop: DispatchWorkItem?
    public private(set) var isRecording = false

    private let vad: SilenceDetector?                 // nil = VAD off (zero overhead on the audio thread)
    private var onAutoStop: (@MainActor () -> Void)?  // stored so the VAD silence hook can route to it

    // Streaming (MIC_DICTATION P3): the live 16 kHz mono Float buffer WhisperKit consumes, shared between
    // the audio-thread sink (appends) and the main actor (snapshots) via an OSAllocatedUnfairLock — the
    // same Sendable cross-thread discipline as the VAD hook. nil when not streaming → zero overhead.
    private let liveBuffer: OSAllocatedUnfairLock<[Float]>?

    public init(maxSeconds: TimeInterval = 120, vad: SilenceDetector? = nil, streaming: Bool = false) {
        self.maxSeconds = maxSeconds
        self.vad = vad
        self.liveBuffer = streaming ? OSAllocatedUnfairLock(initialState: []) : nil
    }

    enum Failure: LocalizedError {
        case alreadyRecording
        case sinkSetupFailed

        public var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "Already recording."
            case .sinkSetupFailed:  return "Could not start the microphone recorder."
            }
        }
    }

    /// Mic-permission gate. `.notDetermined` → system prompt; returns whether access is granted.
    /// Call this BEFORE `start()`. `.denied`/`.restricted` → false (caller points the user to
    /// System Settings › Privacy › Microphone). Mic ≠ Accessibility — the "no Accessibility" story holds.
    public static func ensureMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default:             return false
        }
    }

    #if os(iOS)
    /// Configure + activate the shared audio session for recording. Required on iOS before touching the input
    /// node (see `start()`). `.playAndRecord` (not `.record`) so an in-app player can still play afterwards
    /// without a category flip; `.defaultToSpeaker` routes to the speaker. (Bluetooth-mic input is deferred:
    /// the new `.allowBluetoothHFP` option is a newer-SDK symbol we avoid under the iOS-17 deployment floor.)
    private static func activateRecordSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
    }
    #endif

    /// Begin capturing; returns the WAV URL being written. Throws if already recording or the sink can't
    /// be set up. `onAutoStop` fires on the main actor if `maxSeconds` elapses first. The mic-permission
    /// check is the caller's job (`ensureMicAccess()`) — `start()` assumes access is granted.
    @discardableResult
    public func start(onAutoStop: @escaping @MainActor () -> Void) throws -> URL {
        guard !isRecording else { throw Failure.alreadyRecording }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parla-dictation-\(UUID().uuidString).wav")

        self.onAutoStop = onAutoStop

        // iOS: the audio session MUST be `.playAndRecord` + active BEFORE reading the input node's format or
        // starting the engine — otherwise `inputNode.outputFormat(forBus:)` reports 0 ch / 0 Hz and the mic is
        // silently dead. (macOS has no AVAudioSession; the input node is always live.)
        #if os(iOS)
        try Self.activateRecordSession()
        #endif

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        // VAD (opt-in): on a run of silence the sink fires this ONCE → hop to main → the SAME `onAutoStop`
        // channel the 120 s cap uses (single stop + transcribe). Audio-thread buffers never cross isolation;
        // only this Sendable signal does. Mirrors the FolderWatcher `MainActor.assumeIsolated` hand-off.
        let onSilence: (@Sendable () -> Void)? = vad == nil ? nil : { @Sendable [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fireAutoStop() } }
        }
        guard let sink = WavSink(url: url, source: inFormat, target: Self.targetFormat,
                                 detector: vad, onSilence: onSilence, liveBuffer: liveBuffer) else {
            throw Failure.sinkSetupFailed
        }

        installMicTap(on: input, format: inFormat, sink: sink)

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        outputURL = url
        isRecording = true

        if maxSeconds > 0 {
            // Only NOTIFY on timeout — the owner (AppModel) performs the single `stop()` that captures the
            // WAV URL and transcribes it. Stopping here too would DOUBLE-stop: the owner's `stop()` then
            // hits its `guard isRecording` and returns nil → the whole recording is lost and a false
            // "empty" error shows. (`stop()` is idempotent, so the manual-stop path is unaffected.)
            let work = DispatchWorkItem { onAutoStop() }
            autoStop = work
            DispatchQueue.main.asyncAfter(deadline: .now() + maxSeconds, execute: work)
        }
        return url
    }

    /// Stop capturing and finalize the WAV. Returns its URL (nil if not recording). Idempotent.
    /// `engine.stop()` synchronizes the render thread, so no tap block is in flight when this returns —
    /// the sink then deallocs and the `AVAudioFile` finalizes on disk.
    @discardableResult
    public func stop() -> URL? {
        guard isRecording else { return nil }
        autoStop?.cancel(); autoStop = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        return outputURL
    }

    /// Stop and DISCARD the recording without transcribing — for app teardown (e.g. quit while recording).
    /// Removes the temp WAV too, so it can't orphan in the temp dir.
    public func cancel() {
        if let url = stop() { try? FileManager.default.removeItem(at: url) }
    }

    /// Route the VAD silence signal to the same auto-stop handler the 120 s cap uses. Always on the main actor.
    private func fireAutoStop() { onAutoStop?() }

    // MARK: Streaming (MIC_DICTATION P3) — live Float buffer access

    /// Number of 16 kHz mono Float samples captured so far (0 when not streaming) — drives the orchestrator's
    /// window cadence. Lock-guarded; safe to read from the main actor while the audio thread appends.
    public var liveSampleCount: Int { liveBuffer?.withLock { $0.count } ?? 0 }

    /// Snapshot copy of the captured Float samples from `start` (sample index) to now; empty when not
    /// streaming or `start` is past the end. Keep `start` near the tail — the copy runs under the lock the
    /// audio thread appends through, so a whole-buffer copy could briefly stall capture. The orchestrator
    /// only ever windows a bounded un-confirmed tail, so the lock is held for sub-millisecond copies.
    public func liveSamples(from start: Int = 0) -> [Float] {
        guard let liveBuffer else { return [] }
        return liveBuffer.withLock { buf in start < buf.count ? Array(buf[start...]) : [] }
    }

    /// 16-bit PCM → Float in [-1, 1), matching how WhisperKit reads an Int16 WAV (÷32768). Pulled out so the
    /// streaming Float feed is bit-identical to the file path — and unit-testable (the live tap itself isn't).
    /// `nonisolated`: it's pure and the audio-thread sink calls it off the main actor.
    public nonisolated static func normalize(_ samples: [Int16]) -> [Float] {
        samples.map { Float($0) / 32768.0 }
    }
}

/// Install the real-time input tap from a NONISOLATED context, so the tap block does NOT inherit
/// `MicRecorder`'s `@MainActor` isolation. AVFAudio invokes the block on CoreAudio's render thread; an
/// isolated block asserts it's on the main actor there and traps (`EXC_BREAKPOINT` in
/// `swift_task_isCurrentExecutor`). A nonisolated, non-`@Sendable` block runs correctly off-main, and the
/// `@preconcurrency import AVFoundation` downgrades the block's `@Sendable`-parameter mismatch (so no
/// Sendable-capture warning — the same clean compile the main-actor version had, minus the crash). `sink` is
/// confined to this block (the audio thread); its only main-actor-shared state is the Sendable `liveBuffer` lock.
private func installMicTap(on input: AVAudioInputNode, format: AVAudioFormat, sink: WavSink) {
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
        sink.append(buffer)
    }
}

/// Real-time WAV sink: resamples each tap buffer to the target format and appends it to an `AVAudioFile`.
/// NOT `Sendable` — created on the main actor, then transferred into the tap block and touched ONLY on the
/// audio thread (never concurrently). Holds ONE `AVAudioConverter` for the whole session so sample-rate
/// conversion keeps its internal state across buffers (correct continuity, no per-buffer boundary glitches).
private final class WavSink {
    private let converter: AVAudioConverter
    private let file: AVAudioFile
    private let target: AVAudioFormat
    private let ratio: Double
    private var detector: SilenceDetector?
    private let onSilence: (@Sendable () -> Void)?
    private var firedSilence = false
    private let liveBuffer: OSAllocatedUnfairLock<[Float]>?   // streaming: mirror frames as Float, else nil

    public init?(url: URL, source: AVAudioFormat, target: AVAudioFormat,
          detector: SilenceDetector? = nil, onSilence: (@Sendable () -> Void)? = nil,
          liveBuffer: OSAllocatedUnfairLock<[Float]>? = nil) {
        guard source.sampleRate > 0,
              let converter = AVAudioConverter(from: source, to: target),
              let file = try? AVAudioFile(forWriting: url, settings: target.settings,
                                          commonFormat: .pcmFormatInt16, interleaved: true)
        else { return nil }
        self.converter = converter
        self.file = file
        self.target = target
        self.ratio = target.sampleRate / source.sampleRate
        self.detector = detector
        self.onSilence = onSilence
        self.liveBuffer = liveBuffer
    }

    public func append(_ input: AVAudioPCMBuffer) {
        guard input.frameLength > 0 else { return }

        // VAD (opt-in): feed this buffer's loudness; on a run of silence (after speech) fire the stop ONCE.
        // The buffer is still written below, so audio up to the silence is kept.
        if !firedSilence, let onSilence, input.format.sampleRate > 0 {
            let dt = Double(input.frameLength) / input.format.sampleRate
            if let stop = detector?.feed(rms: WavSink.rms(of: input), dt: dt), stop {
                firedSilence = true
                onSilence()
            }
        }

        // Output capacity = input frames × (16k / inputRate), plus slack for the resampler's tail.
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        // Feed the buffer once, then signal end-of-input so the converter emits what it can. The "fed"
        // flag lives in an OSAllocatedUnfairLock (a Sendable value) so the @Sendable input block captures
        // no non-Sendable mutable state → zero `#SendableClosureCaptures` warnings, no `@unchecked Sendable`.
        // The lock is uncontended (the converter calls the block serially) → effectively free.
        let fed = OSAllocatedUnfairLock(initialState: false)
        var convErr: NSError?
        let status = converter.convert(to: out, error: &convErr) { _, inStatus in
            let already = fed.withLock { f -> Bool in defer { f = true }; return f }
            if already { inStatus.pointee = .noDataNow; return nil }
            inStatus.pointee = .haveData
            return input
        }
        guard status != .error, out.frameLength > 0 else { return }
        try? file.write(from: out)

        // Streaming (opt-in): mirror the just-written 16 kHz mono Int16 frames into the in-memory Float
        // buffer WhisperKit consumes. Conversion runs lock-free; only the bulk append holds the lock, so
        // the audio thread is never blocked on the main actor's per-sample work.
        if let liveBuffer, let i16 = out.int16ChannelData {
            let chunk = Array(UnsafeBufferPointer(start: i16[0], count: Int(out.frameLength)))   // mono → contiguous
            let floats = MicRecorder.normalize(chunk)
            liveBuffer.withLock { $0.append(contentsOf: floats) }
        }
    }

    /// Mean loudness (RMS) of the first channel — 0 if the buffer isn't deinterleaved Float32 (the VAD
    /// then simply never arms, which is safe). Cheap enough for the real-time tap.
    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        let data = ch[0]
        var sum: Float = 0
        for i in 0..<n { let s = data[i]; sum += s * s }
        return (sum / Float(n)).squareRoot()
    }
}
