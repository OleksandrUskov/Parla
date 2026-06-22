import Foundation
import WhisperKit

// Headless-прогон: ParlaSmoke <wav> [model]
let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: ParlaSmoke <wav-path> [model]")
    exit(1)
}
let wavPath = args[1]
let model = args.count >= 3 ? args[2] : "openai_whisper-tiny"

FileHandle.standardError.write("Загружаю модель \(model)…\n".data(using: .utf8)!)
let kit = try await WhisperKit(WhisperKitConfig(model: model))

FileHandle.standardError.write("Распознаю \(wavPath)…\n".data(using: .utf8)!)
let results: [TranscriptionResult] = try await kit.transcribe(
    audioPath: wavPath,
    decodeOptions: DecodingOptions(task: .transcribe, detectLanguage: true)
)
let text = results.map { $0.text }.joined(separator: " ")
    .trimmingCharacters(in: .whitespacesAndNewlines)

print("LANG=\(results.first?.language ?? "?")")
print("TEXT=\(text)")
