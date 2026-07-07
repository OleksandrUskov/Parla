import Foundation
import ParlaCore

/// macOS `AudioDecoding`: forwards to the vendored LGPL ffmpeg via `AudioConverter`. Stays in the macOS app
/// target (ffmpeg is a spawned subprocess, unavailable on iOS) — iOS ships its own in-process decoder that
/// conforms to the same seam instead (see IOS_PORT.md §2).
struct FFmpegAudioDecoder: AudioDecoding {
    func decodeToWav16k(_ src: URL) throws -> URL { try AudioConverter.toWav16k(src) }

    func splitIntoChunks(_ src: URL, chunkLength: Double) throws -> [URL] {
        try AudioConverter.splitIntoChunks(src, chunkLength: chunkLength)
    }

    var isChunkingAvailable: Bool { AudioConverter.isFFmpegAvailable }

    func renderPlayableM4a(from src: URL, to dest: URL) throws { try AudioConverter.toM4a(src, to: dest) }

    func renderPlayableWav(from src: URL, to dest: URL) throws { try AudioConverter.toPlayableWav(src, to: dest) }
}
