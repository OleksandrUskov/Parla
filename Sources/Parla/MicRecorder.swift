import Foundation
import os
// AVFAudio's AVAudioConverterInputBlock is @Sendable but is called synchronously on the audio thread
// (no real concurrency) — @preconcurrency relaxes the spurious Sendable-capture diagnostics for AVFAudio
// types (e.g. the `AVAudioPCMBuffer` we feed it), mirroring the `@preconcurrency import WhisperKit` seam
// in TranscriptionEngine. No `@unchecked Sendable` needed.
@preconcurrency import AVFoundation

/// Records the microphone straight to a **16 kHz mono Int16 WAV** — WhisperKit's native input format, so a
/// dictation result needs NO ffmpeg decode: the WAV goes straight to `engine.transcribe(wavPath:)` (`.wav`
/// is in `AppModel.avDecodable`, so the dictation path bypasses `wavConverter` entirely).
///
/// Concurrency (we're on Swift 6 `.v6`): the input tap fires on CoreAudio's real-time thread. All capture
/// state (the `AVAudioConverter` + `AVAudioFile`) is owned by a private `WavSink` that is *transferred* into
/// the tap block and touched ONLY from that thread — it never crosses back to the main actor. The engine
/// lifecycle (install/remove tap, start/stop) stays on `@MainActor`; only the final WAV `URL` (a `Sendable`
/// value) is returned to the caller. Teardown is deterministic (`removeTap` + `engine.stop()` in `stop()`),
/// never in `deinit` (mirrors the `FolderWatcher` / `PlaybackController` no-`@MainActor`-deinit discipline).
@MainActor
final class MicRecorder {
    /// WhisperKit's native input: 16 kHz mono Int16 PCM. Recording straight to this skips the whole
    /// ffmpeg / `AudioConverter` decode step for dictation. Pinned by a unit test (`targetFormat` constant).
    static let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: 16_000, channels: 1, interleaved: true)!

    /// Auto-stop a forgotten session so a stuck recording can't grow unbounded. `<= 0` disables it.
    let maxSeconds: TimeInterval

    private let engine = AVAudioEngine()
    private var outputURL: URL?
    private var autoStop: DispatchWorkItem?
    private(set) var isRecording = false

    init(maxSeconds: TimeInterval = 120) { self.maxSeconds = maxSeconds }

    enum Failure: LocalizedError {
        case alreadyRecording
        case sinkSetupFailed

        var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "Already recording."
            case .sinkSetupFailed:  return "Could not start the microphone recorder."
            }
        }
    }

    /// Mic-permission gate. `.notDetermined` → system prompt; returns whether access is granted.
    /// Call this BEFORE `start()`. `.denied`/`.restricted` → false (caller points the user to
    /// System Settings › Privacy › Microphone). Mic ≠ Accessibility — the "no Accessibility" story holds.
    static func ensureMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default:             return false
        }
    }

    /// Begin capturing; returns the WAV URL being written. Throws if already recording or the sink can't
    /// be set up. `onAutoStop` fires on the main actor if `maxSeconds` elapses first. The mic-permission
    /// check is the caller's job (`ensureMicAccess()`) — `start()` assumes access is granted.
    @discardableResult
    func start(onAutoStop: @escaping @MainActor () -> Void) throws -> URL {
        guard !isRecording else { throw Failure.alreadyRecording }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parla-dictation-\(UUID().uuidString).wav")

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard let sink = WavSink(url: url, source: inFormat, target: Self.targetFormat) else {
            throw Failure.sinkSetupFailed
        }

        // `sink` is transferred into the @Sendable tap block and used ONLY on the audio thread — it is
        // never referenced from the main actor again, so this is a clean region transfer (no shared state).
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
            sink.append(buffer)
        }

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
    func stop() -> URL? {
        guard isRecording else { return nil }
        autoStop?.cancel(); autoStop = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        return outputURL
    }

    /// Stop and DISCARD the recording without transcribing — for app teardown (e.g. quit while recording).
    /// Removes the temp WAV too, so it can't orphan in the temp dir.
    func cancel() {
        if let url = stop() { try? FileManager.default.removeItem(at: url) }
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

    init?(url: URL, source: AVAudioFormat, target: AVAudioFormat) {
        guard source.sampleRate > 0,
              let converter = AVAudioConverter(from: source, to: target),
              let file = try? AVAudioFile(forWriting: url, settings: target.settings,
                                          commonFormat: .pcmFormatInt16, interleaved: true)
        else { return nil }
        self.converter = converter
        self.file = file
        self.target = target
        self.ratio = target.sampleRate / source.sampleRate
    }

    func append(_ input: AVAudioPCMBuffer) {
        guard input.frameLength > 0 else { return }
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
    }
}
