import Foundation
@preconcurrency import WhisperKit   // WhisperKit isn't Sendable-annotated — mirrors TranscriptionEngine.swift

// Headless check: ParlaSmoke <wav> [model] [lang]
// `lang` pins the decode language ("" or omitted = auto-detect, the app's default). Pinning matters for A/B
// measurement: per-chunk auto-detection adds variance that has nothing to do with what is being compared.
// If the model is already on disk — load it LOCALLY (modelFolder + download:false), just like the app does.
let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: ParlaSmoke <wav-path> [model]")
    exit(1)
}
let wavPath = args[1]
let model = args.count >= 3 ? args[2] : "openai_whisper-tiny"
let pinnedLang: String? = (args.count >= 4 && !args[3].isEmpty) ? args[3] : nil

let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml/\(model)", isDirectory: true)
let isLocal = !(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty)
FileHandle.standardError.write("local=\(isLocal)  folder=\(folder.path)\n".data(using: .utf8)!)

let kit: WhisperKit
if isLocal {
    FileHandle.standardError.write("→ local load (download:false), offline\n".data(using: .utf8)!)
    kit = try await WhisperKit(WhisperKitConfig(model: model, modelFolder: folder.path, download: false))
} else {
    FileHandle.standardError.write("→ normal load (downloading)\n".data(using: .utf8)!)
    kit = try await WhisperKit(WhisperKitConfig(model: model))
}

let results: [TranscriptionResult] = try await kit.transcribe(
    audioPath: wavPath,
    decodeOptions: DecodingOptions(task: .transcribe, language: pinnedLang, detectLanguage: pinnedLang == nil)
)
let text = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
print("LANG=\(results.first?.language ?? "?")")
print("TEXT=\(text)")
