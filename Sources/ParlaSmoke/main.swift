import Foundation
import WhisperKit

// Headless-проверка: ParlaSmoke <wav> [model]
// Если модель уже на диске — грузим ЛОКАЛЬНО (modelFolder + download:false), как в приложении.
let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: ParlaSmoke <wav-path> [model]")
    exit(1)
}
let wavPath = args[1]
let model = args.count >= 3 ? args[2] : "openai_whisper-tiny"

let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(model)", isDirectory: true)
let isLocal = !(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty)
FileHandle.standardError.write("local=\(isLocal)  folder=\(folder.path)\n".data(using: .utf8)!)

let kit: WhisperKit
if isLocal {
    FileHandle.standardError.write("→ локальная загрузка (download:false), офлайн\n".data(using: .utf8)!)
    kit = try await WhisperKit(WhisperKitConfig(model: model, modelFolder: folder.path, download: false))
} else {
    FileHandle.standardError.write("→ обычная загрузка (скачивание)\n".data(using: .utf8)!)
    kit = try await WhisperKit(WhisperKitConfig(model: model))
}

let results: [TranscriptionResult] = try await kit.transcribe(
    audioPath: wavPath,
    decodeOptions: DecodingOptions(task: .transcribe, detectLanguage: true)
)
let text = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
print("LANG=\(results.first?.language ?? "?")")
print("TEXT=\(text)")
