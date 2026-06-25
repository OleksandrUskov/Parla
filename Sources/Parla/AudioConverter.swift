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
    /// buffer and deadlock the process; stdout → /dev/null. A watchdog bounds a *wedged* child (the
    /// pipe-drain fix doesn't help if ffmpeg simply hangs): after `timeout` seconds it terminates the
    /// process, which closes stderr and lets the read return. Audio decode/transcode runs far faster
    /// than realtime, so a legit job never reaches the (generous) default; `timeout <= 0` disables it.
    /// Returns (exit status, last 3 stderr lines).
    static func runCapturingStderr(_ proc: Process, timeout: TimeInterval = 1800) throws -> (status: Int32, stderrTail: String) {
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()

        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        if timeout > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog) }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()   // drains until the child closes stderr (on exit/terminate)
        proc.waitUntilExit()
        watchdog.cancel()                                                  // exited in time → stand the watchdog down
        let err = String(data: errData, encoding: .utf8) ?? ""
        let tail = err.split(separator: "\n").suffix(3).joined(separator: "\n")
        return (proc.terminationStatus, tail)
    }

    /// System ffmpeg install locations (Homebrew/standard) — dev machines, `swift run`.
    static let systemFfmpegCandidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]

    /// The vendored LGPL binary inside the app bundle (Contents/Resources/Helpers/ffmpeg), or nil
    /// when running outside a bundle (e.g. `swift run`) or before one is shipped.
    static func bundledFfmpegURL() -> URL? {
        Bundle.main.url(forResource: "ffmpeg", withExtension: nil, subdirectory: "Helpers")
    }

    /// Resolve ffmpeg: the bundled binary (zero user setup) first, else a system install.
    static func ffmpegURL() -> URL? {
        resolveFfmpeg(bundled: bundledFfmpegURL(), systemCandidates: systemFfmpegCandidates)
    }

    /// Pure resolver (testable): bundled wins when present + executable, else the first executable
    /// system candidate, else nil.
    static func resolveFfmpeg(bundled: URL?, systemCandidates: [String]) -> URL? {
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        for path in systemCandidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Whether the resolved ffmpeg is the bundled one (drives the Settings "bundled vs system" label).
    static var isUsingBundledFfmpeg: Bool {
        guard let resolved = ffmpegURL(), let bundled = bundledFfmpegURL() else { return false }
        return resolved.path == bundled.path
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
