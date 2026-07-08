#if os(iOS)
import Foundation
import AVFoundation
import CoreMedia
import opus

/// iOS in-process `AudioDecoding` (iOS-port P1.3). The macOS ffmpeg subprocess is impossible on iOS, so the
/// transcription pipeline's decode seam is served here by two pure-library lanes:
///
/// - **LANE-1 — Ogg/Opus (Opusfile):** Telegram `.ogg`/`.opus` → a mono Float WAV, stream-decoded page-by-page
///   so a long recording never materializes in RAM (a 70-min file ≈ 200M floats ≈ 800 MB otherwise → jetsam,
///   IOS_PORT §2). AVFoundation can't open Ogg/Opus, hence the dedicated `libopusfile` path.
/// - **LANE-2 — everything else AVFoundation can demux (`AVAssetReader`):** mp4/mov/m4v/flac/… → a 16 kHz mono
///   Float WAV. The reader resamples + downmixes for us and we drain it one `CMSampleBuffer` at a time, so
///   memory stays O(one buffer) regardless of length. Throws when the source has no readable audio track (the
///   caller surfaces the error / falls back — best-effort).
///
/// AV-native containers (m4a/mp3/wav/aac/caf/aiff — `AppModel.avDecodable`) never reach this seam at all;
/// WhisperKit opens them directly. Both lanes emit a Float32 WAV; WhisperKit's `transcribe(wavPath:)` resamples
/// to 16 kHz on load (Lane-1 emits 48 kHz native, Lane-2 emits 16 kHz), so no extra resample is needed.
///
/// FOLLOW-UPS (throw / no-op for now): streaming `splitIntoChunks` for the long-audio per-chunk progress UI,
/// and playback renders. webm is scoped OUT of iOS v1 (§2 — no clean in-process decoder).
public struct OpusAudioDecoder: AudioDecoding {
    public init() {}

    private static let opusExtensions: Set<String> = ["ogg", "oga", "opus"]

    public func decodeToWav16k(_ src: URL) throws -> URL {
        if Self.opusExtensions.contains(src.pathExtension.lowercased()) {
            return try Self.decodeOpusToWav(src)         // Lane-1: Ogg/Opus via libopusfile
        }
        return try Self.decodeViaAVAssetReader(src)      // Lane-2: mp4/mov/flac/… via AVFoundation
    }

    /// Long-audio chunking is a follow-up → returning `[]` makes the pipeline fall back to a single pass
    /// (WhisperKit windows long audio internally, so this is correct, just without our per-chunk progress UI).
    public func splitIntoChunks(_ src: URL, chunkLength: Double) throws -> [URL] { [] }
    public var isChunkingAvailable: Bool { false }
    public func renderPlayableM4a(from src: URL, to dest: URL) throws { throw AudioDecodingError.noDecoderAvailable }
    public func renderPlayableWav(from src: URL, to dest: URL) throws { throw AudioDecodingError.noDecoderAvailable }

    // MARK: - Lane 1 — Ogg/Opus (libopusfile)

    /// Stream-decode Ogg/Opus to a mono Float32 WAV (48 kHz). `op_open_file` reads the container incrementally
    /// from disk; each `op_read_float` page is downmixed to mono and appended to the AVAudioFile → O(one page)
    /// memory regardless of length. Returns the temp WAV URL (the caller removes it after transcription).
    static func decodeOpusToWav(_ src: URL) throws -> URL {
        var err: Int32 = 0
        guard let file = op_open_file(src.path, &err), err == 0 else { throw AudioDecodingError.noDecoderAvailable }
        defer { op_free(file) }

        let channels = Int(op_channel_count(file, -1))
        guard channels > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 5760)   // Opusfile yields ≤ 5760 frames/channel per call
        else { throw AudioDecodingError.noDecoderAvailable }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("parla-opus-\(UUID().uuidString).wav")
        let out = try AVAudioFile(forWriting: dest, settings: format.settings)

        var interleaved = [Float](repeating: 0, count: 5760 * channels)
        while true {
            let n = interleaved.withUnsafeMutableBufferPointer {
                op_read_float(file, $0.baseAddress, Int32($0.count), nil)   // returns frames PER CHANNEL, 0 = EOF, <0 = error
            }
            if n < 0 { throw AudioDecodingError.noDecoderAvailable }
            if n == 0 { break }
            let frames = Int(n)
            let dst = mono.floatChannelData![0]
            if channels == 1 {
                interleaved.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: frames) }
            } else {
                for f in 0 ..< frames {                                     // downmix to mono
                    var acc: Float = 0
                    for c in 0 ..< channels { acc += interleaved[f * channels + c] }
                    dst[f] = acc / Float(channels)
                }
            }
            mono.frameLength = AVAudioFrameCount(frames)
            try out.write(from: mono)
        }
        return dest
    }

    // MARK: - Lane 2 — AVAssetReader (mp4/mov/m4v/flac/…)

    /// Output PCM spec handed to `AVAssetReaderTrackOutput`: the reader resamples the source to 16 kHz and
    /// downmixes to mono for us, delivering interleaved Float32 (mono → interleaved == non-interleaved).
    /// Computed (not a stored `static let`) so the `[String: Any]` isn't a non-Sendable global under `.v6`.
    static var pcm16kMonoSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Decode any AVFoundation-demuxable container (mp4/mov/m4v/flac/…) to a 16 kHz mono Float32 WAV, streaming
    /// one `CMSampleBuffer` at a time so memory stays bounded on a long file. Throws when there's no readable
    /// audio track (unknown/corrupt container, or a video-only file). The synchronous `tracks(withMediaType:)`
    /// is intentional: this seam is `throws`-sync and always runs off the main actor (`Task.detached` in the
    /// pipeline), so the brief synchronous property load is fine.
    static func decodeViaAVAssetReader(_ src: URL) throws -> URL {
        let asset = AVURLAsset(url: src)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw AudioDecodingError.noDecoderAvailable   // no audio stream / unreadable container
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: Self.pcm16kMonoSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioDecodingError.noDecoderAvailable }
        reader.add(output)

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        else { throw AudioDecodingError.noDecoderAvailable }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("parla-av-\(UUID().uuidString).wav")
        let out = try AVAudioFile(forWriting: dest, settings: format.settings)

        guard reader.startReading() else {
            try? FileManager.default.removeItem(at: dest)
            throw reader.error ?? AudioDecodingError.noDecoderAvailable
        }

        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sample) }   // drop the backing store promptly (streaming)
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let byteCount = CMBlockBufferGetDataLength(block)
            let frames = byteCount / MemoryLayout<Float>.stride
            guard frames > 0,
                  let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
            else { continue }
            buf.frameLength = AVAudioFrameCount(frames)
            let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount,
                                                    destination: buf.floatChannelData![0])
            guard status == kCMBlockBufferNoErr else { continue }
            try out.write(from: buf)
        }

        guard reader.status != .failed else {
            try? FileManager.default.removeItem(at: dest)
            throw reader.error ?? AudioDecodingError.noDecoderAvailable
        }
        return dest
    }
}
#endif
