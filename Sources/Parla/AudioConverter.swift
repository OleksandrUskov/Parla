import Foundation
import AVFoundation

/// Converts any audio/video to 16 kHz mono WAV via ffmpeg.
/// Needed because Telegram serves .ogg/Opus, which AVFoundation (used by
/// WhisperKit to load audio) can't open.
enum AudioConverter {
    enum Failure: LocalizedError {
        case ffmpegNotFound
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return L("error.ffmpeg.missing")
            case .conversionFailed(let detail):
                return Lf("error.decode.failed", detail)
            }
        }
    }

    /// Run a Process, draining stderr to EOF *before* waitUntilExit so a flood can't fill the pipe
    /// buffer and deadlock the process; stdout → /dev/null. Returns (exit status, last 3 stderr lines).
    static func runCapturingStderr(_ proc: Process) throws -> (status: Int32, stderrTail: String) {
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()   // drains until the child closes stderr (on exit)
        proc.waitUntilExit()
        let err = String(data: errData, encoding: .utf8) ?? ""
        let tail = err.split(separator: "\n").suffix(3).joined(separator: "\n")
        return (proc.terminationStatus, tail)
    }

    static func ffmpegURL() -> URL? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// ffmpeg args for the 16 kHz mono WAV decode. Pure (no I/O) so a test can assert the quiet
    /// flags are present — they're the Tier-0 deadlock guard (`-loglevel error`/`-nostats` keep the
    /// stderr stream small enough that `runCapturingStderr` never blocks). Don't drop them.
    static func wavArgs(src: String, out: String) -> [String] {
        ["-hide_banner", "-loglevel", "error", "-nostats",
         "-y", "-i", src, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", out]
    }

    /// ffmpeg args for the AAC .m4a playback rendition. Same quiet-flag guard as `wavArgs`.
    static func m4aArgs(src: String, dest: String) -> [String] {
        ["-hide_banner", "-loglevel", "error", "-nostats",
         "-y", "-i", src, "-vn", "-c:a", "aac", "-b:a", "96k", dest]
    }

    static func toWav16k(_ src: URL) throws -> URL {
        guard let ffmpeg = ffmpegURL() else { throw Failure.ffmpegNotFound }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("parla-\(UUID().uuidString).wav")

        let proc = Process()
        proc.executableURL = ffmpeg
        proc.arguments = wavArgs(src: src.path, out: out.path)
        let (status, tail) = try runCapturingStderr(proc)
        guard status == 0 else { throw Failure.conversionFailed(tail) }
        return out
    }

    /// Render for playback: any source → AAC .m4a. Needed for Opus/Ogg/video containers
    /// that AVAudioPlayer can't open. `-vn` drops the video track.
    static func toM4a(_ src: URL, to dest: URL) throws {
        guard let ffmpeg = ffmpegURL() else { throw Failure.ffmpegNotFound }

        let proc = Process()
        proc.executableURL = ffmpeg
        proc.arguments = m4aArgs(src: src.path, dest: dest.path)
        let (status, tail) = try runCapturingStderr(proc)
        guard status == 0 else { throw Failure.conversionFailed(tail) }
    }

    // MARK: Long-audio support

    /// Actual audio length in seconds (AVFoundation). nil if the file can't be opened.
    static func duration(of path: String) -> Double? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
        let sr = file.fileFormat.sampleRate
        return sr > 0 ? Double(file.length) / sr : nil
    }

    /// Whether an ffmpeg binary is resolvable right now — required to split long files into chunks.
    static var isFFmpegAvailable: Bool { ffmpegURL() != nil }

    /// ffmpeg args for the segment-muxer split into fixed-length 16 kHz mono WAV chunks.
    /// Same quiet-flag guard as `wavArgs` (Tier-0 deadlock prevention).
    static func chunkArgs(src: String, segmentTime: Int, outPattern: String) -> [String] {
        ["-hide_banner", "-loglevel", "error", "-nostats", "-y", "-i", src,
         "-f", "segment", "-segment_time", String(segmentTime),
         "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", outPattern]
    }

    /// Split audio into ~`chunkLength`-second 16 kHz mono WAV chunks via ffmpeg's segment muxer.
    /// Returns the chunk URLs in order (all under one temp dir — the caller removes that dir).
    /// Throws if ffmpeg is missing or the split fails.
    static func splitIntoChunks(_ src: URL, chunkLength: Double) throws -> [URL] {
        guard let ffmpeg = ffmpegURL() else { throw Failure.ffmpegNotFound }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parla-chunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = ffmpeg
        proc.arguments = chunkArgs(src: src.path, segmentTime: Int(chunkLength),
                                   outPattern: dir.appendingPathComponent("chunk_%04d.wav").path)
        let (status, tail) = try runCapturingStderr(proc)
        guard status == 0 else { throw Failure.conversionFailed(tail) }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
