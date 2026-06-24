import Foundation

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
}
