import Foundation

/// Конвертация любого аудио/видео в 16 kHz mono WAV через ffmpeg.
/// Нужно, потому что Telegram отдаёт .ogg/Opus, а AVFoundation (которым грузит
/// WhisperKit) его не открывает.
enum AudioConverter {
    enum Failure: LocalizedError {
        case ffmpegNotFound
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return "Не найден ffmpeg. Установи его командой:  brew install ffmpeg"
            case .conversionFailed(let detail):
                return "Не удалось декодировать аудио.\n\(detail)"
            }
        }
    }

    static func ffmpegURL() -> URL? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func toWav16k(_ src: URL) throws -> URL {
        guard let ffmpeg = ffmpegURL() else { throw Failure.ffmpegNotFound }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("parla-\(UUID().uuidString).wav")

        let proc = Process()
        proc.executableURL = ffmpeg
        proc.arguments = ["-y", "-i", src.path, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", out.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let tail = err.split(separator: "\n").suffix(3).joined(separator: "\n")
            throw Failure.conversionFailed(tail)
        }
        return out
    }
}
