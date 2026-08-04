import Foundation
import AVFoundation

/// Seam over audio decoding for the transcription pipeline. Both platforms inject the same in-process
/// decoder (`OpusAudioDecoder` — opusfile + AVAssetReader, no subprocess). Keeping `AppModel` and
/// `TranscriptionEngine` free of any subprocess dependency is what keeps the whole transcription path portable.
/// Lets a caller stop a decode that is taking too long — or that the user cancelled.
///
/// This exists because the decode loops had **no way out**. They ran inside `Task.detached`, which does not
/// inherit cancellation, and neither loop checked anything, so `cancelTranscription()` could not stop a decode
/// in progress: the Cancel button was a lie for the entire decode phase. The old ffmpeg subprocess had a 1800 s
/// timeout; nothing replaced it when the decode moved in-process, so a wedged read had nothing to stop it either.
///
/// `@unchecked Sendable` with a lock, because the flag is written from the main actor (the Cancel button) and
/// read from whatever thread the decode runs on.
public final class DecodeControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let deadline: Date?

    /// - Parameter timeout: how long a single decode may run before it is treated as wedged. The default is
    ///   deliberately generous — this is a last-resort guard against a hang, not a performance policy. A
    ///   three-hour podcast decodes in minutes; anything past 30 minutes is broken, not slow.
    public init(timeout: TimeInterval? = 1800) {
        deadline = timeout.map { Date().addingTimeInterval($0) }
    }

    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Call this in every read loop, once per buffer. Throws rather than returning a flag so a loop cannot
    /// forget to act on it.
    public func check() throws {
        if isCancelled { throw AudioDecodingError.cancelled }
        if let deadline, Date() > deadline { throw AudioDecodingError.timedOut }
    }
}

public protocol AudioDecoding: Sendable {
    /// Decode any source container to a 16 kHz mono WAV the engine can read (opusfile / AVAssetReader → PCM
    /// WAV, in-process on both platforms). Throws when no decoder can handle the source.
    func decodeToWav16k(_ src: URL) throws -> URL

    /// Same, but interruptible. Default forwards to the plain version, so existing conformances (and every test
    /// double) keep compiling untouched; the real decoder overrides it.
    func decodeToWav16k(_ src: URL, control: DecodeControl?) throws -> URL

    /// Split a long source into ~`chunkLength`-second 16 kHz mono WAV chunks (all under one temp dir the
    /// caller removes). An empty result = the source produced no audio → the caller falls back to a single pass.
    func splitIntoChunks(_ src: URL, chunkLength: Double) throws -> [URL]

    /// Same, but interruptible. Default forwards to the plain version.
    func splitIntoChunks(_ src: URL, chunkLength: Double, control: DecodeControl?) throws -> [URL]

    /// Whether chunking is possible right now (the in-process decoder always is). Gates the long-audio path.
    var isChunkingAvailable: Bool { get }

    /// Render a compact AAC .m4a playback rendition (for containers AVAudioPlayer can't open directly).
    /// In-process (AVFoundation) on both platforms. Best-effort — the caller falls back on throw.
    func renderPlayableM4a(from src: URL, to dest: URL) throws

    /// Fallback playback render: a plain PCM .wav, used when the AAC render fails on an exotic source.
    func renderPlayableWav(from src: URL, to dest: URL) throws
}

/// Thrown by the inert Core decoder when no platform decoder has been wired in (e.g. a unit test that
/// exercises a decode path without injecting one). Production always wires a real decoder via the app factory.
public enum AudioDecodingError: LocalizedError {
    case noDecoderAvailable
    /// The user pressed Cancel while the file was still being decoded.
    case cancelled
    /// The decode ran past its deadline — a wedge, not slowness. Replaces the watchdog the ffmpeg subprocess had.
    case timedOut
    /// The stream kept returning gaps instead of audio. An unbounded `OP_HOLE` retry could spin here forever.
    case corruptStream

    public var errorDescription: String? {
        switch self {
        case .noDecoderAvailable: return L("error.decode.unsupported")
        case .cancelled:          return L("error.decode.cancelled")
        case .timedOut:           return L("error.decode.timeout")
        case .corruptStream:      return L("error.decode.corrupt")
        }
    }
}

extension AudioDecoding {
    public func decodeToWav16k(_ src: URL, control: DecodeControl?) throws -> URL { try decodeToWav16k(src) }
    public func splitIntoChunks(_ src: URL, chunkLength: Double, control: DecodeControl?) throws -> [URL] {
        try splitIntoChunks(src, chunkLength: chunkLength)
    }
}

/// Inert `AudioDecoding` default: the Core ships this so `AppModel` has no compile-time dependency on any
/// platform decoder. The apps inject `OpusAudioDecoder` via the app factory; a
/// decode/render call that reaches this default throws / no-ops gracefully (best-effort paths tolerate it).
public struct UnavailableAudioDecoder: AudioDecoding {
    public init() {}
    public func decodeToWav16k(_ src: URL) throws -> URL { throw AudioDecodingError.noDecoderAvailable }
    public func splitIntoChunks(_ src: URL, chunkLength: Double) throws -> [URL] { [] }
    public var isChunkingAvailable: Bool { false }
    public func renderPlayableM4a(from src: URL, to dest: URL) throws { throw AudioDecodingError.noDecoderAvailable }
    public func renderPlayableWav(from src: URL, to dest: URL) throws { throw AudioDecodingError.noDecoderAvailable }
}

/// Actual audio length in seconds via AVFoundation — platform-agnostic (no ffmpeg), so it lives OUTSIDE the
/// subprocess seam: every call site hands it a file `AVAudioFile` can open (a decoded WAV, or an AVFoundation
/// source that skipped decoding). Returns nil when the file can't be opened, and each caller then falls back.
public enum AudioDuration {
    public static func seconds(ofFileAt path: String) -> Double? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let sr = file.fileFormat.sampleRate
        return sr > 0 ? Double(file.length) / sr : nil
    }
}

/// Container duration (seconds) via `AVURLAsset` — reads the media header WITHOUT decoding, so it's the cheap
/// up-front probe the free/Pro length gate uses before any work begins. Covers every AVFoundation-readable
/// container (mp4/mov/m4a/mp3/wav/flac/aac/caf/aiff/3gp…). Returns nil when the header can't be read — notably
/// Ogg/Opus, which AVFoundation can't demux (and those short Telegram voice notes sit under the free cap
/// anyway), so the gate simply never blocks what it can't measure here.
public enum MediaDuration {
    public static func seconds(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let cm = try? await asset.load(.duration) else { return nil }
        let secs = CMTimeGetSeconds(cm)
        return secs.isFinite && secs > 0 ? secs : nil
    }
}
