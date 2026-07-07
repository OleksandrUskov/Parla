#if os(iOS)
import Foundation
import AVFoundation
import opus

/// iOS in-process `AudioDecoding` (iOS-port P1.3). The macOS ffmpeg subprocess is impossible on iOS, so the
/// transcription pipeline's decode seam is served here by a pure-library Opusfile path.
///
/// LANE-1 (shipped): Telegram **Ogg/Opus** → a mono Float WAV, stream-decoded page-by-page so a long recording
/// never materializes in RAM (a 70-min file ≈ 200M floats ≈ 800 MB otherwise → jetsam, IOS_PORT §2). The WAV is
/// at the Opus-native 48 kHz; WhisperKit's `transcribe(wavPath:)` resamples to 16 kHz on load, so no separate
/// resample is needed. AV-native containers (m4a/mp3/wav/aac/caf/aiff — `AppModel.avDecodable`) never reach this
/// seam; WhisperKit opens them directly.
///
/// FOLLOW-UPS (throw for now → the caller surfaces an error / falls back gracefully): Lane-2 (AVAssetReader for
/// mp4/mov/flac), streaming `splitIntoChunks` for the long-audio progress UI, and playback renders. webm is
/// scoped OUT of iOS v1 (§2 — no clean in-process decoder).
public struct OpusAudioDecoder: AudioDecoding {
    public init() {}

    private static let opusExtensions: Set<String> = ["ogg", "oga", "opus"]

    public func decodeToWav16k(_ src: URL) throws -> URL {
        guard Self.opusExtensions.contains(src.pathExtension.lowercased()) else {
            throw AudioDecodingError.noDecoderAvailable   // Lane-2 (mp4/mov/flac via AVAssetReader) is a follow-up
        }
        return try Self.decodeOpusToWav(src)
    }

    /// Long-audio chunking is a follow-up → returning `[]` makes the pipeline fall back to a single pass
    /// (WhisperKit windows long audio internally, so this is correct, just without our per-chunk progress UI).
    public func splitIntoChunks(_ src: URL, chunkLength: Double) throws -> [URL] { [] }
    public var isChunkingAvailable: Bool { false }
    public func renderPlayableM4a(from src: URL, to dest: URL) throws { throw AudioDecodingError.noDecoderAvailable }
    public func renderPlayableWav(from src: URL, to dest: URL) throws { throw AudioDecodingError.noDecoderAvailable }

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
}
#endif
