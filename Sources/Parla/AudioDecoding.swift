import Foundation
import AVFoundation

/// Seam over audio decoding/transcoding for the transcription pipeline. macOS drives the vendored LGPL
/// ffmpeg (`FFmpegAudioDecoder` → `AudioConverter`); iOS will inject an in-process opusfile + AVAssetReader
/// implementation (see IOS_PORT.md §2). Keeping `AppModel` and `TranscriptionEngine`
/// free of any subprocess dependency is what lets the whole transcription path port to iOS unchanged.
protocol AudioDecoding: Sendable {
    /// Decode any source container to a 16 kHz mono WAV the engine can read. macOS: an ffmpeg re-encode;
    /// iOS: opusfile / AVAssetReader → PCM WAV. Throws when no decoder can handle the source.
    func decodeToWav16k(_ src: URL) throws -> URL

    /// Split a long source into ~`chunkLength`-second 16 kHz mono WAV chunks (all under one temp dir the
    /// caller removes). An empty result = the source produced no audio → the caller falls back to a single pass.
    func splitIntoChunks(_ src: URL, chunkLength: Double) throws -> [URL]

    /// Whether chunking is possible right now (macOS: an ffmpeg binary is resolvable). Gates the long-audio path.
    var isChunkingAvailable: Bool { get }
}

/// Actual audio length in seconds via AVFoundation — platform-agnostic (no ffmpeg), so it lives OUTSIDE the
/// subprocess seam: every call site hands it a file `AVAudioFile` can open (a decoded WAV, or an AVFoundation
/// source that skipped decoding). Returns nil when the file can't be opened, and each caller then falls back.
enum AudioDuration {
    static func seconds(ofFileAt path: String) -> Double? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let sr = file.fileFormat.sampleRate
        return sr > 0 ? Double(file.length) / sr : nil
    }
}
