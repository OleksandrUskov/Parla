import Foundation
@preconcurrency import WhisperKit   // WhisperKit isn't Sendable-annotated — mirrors TranscriptionEngine.swift

// ParlaStreamEval — RU/UK streaming-vs-offline WER harness (MIC_DICTATION P3 gate).
//
// For each audio file in a directory, decode it two ways with the SAME model + explicit language:
//   (a) OFFLINE  — one full-utterance decode (what finishDictation saves today).
//   (b) STREAMED — a simulated sliding-window decode that MIRRORS the shipped StreamingReconciler
//                  (confirm-all-but-holdback, single-word boundary dedup, 1.5 s cadence, 15 s window clamp,
//                  10 s force-flush). This is the text the "save the streamed result" option would store.
// Then report WER of each against the hand-verified reference transcript, so we can SEE how much RU/UK
// streaming degrades (and eyeball chunk-boundary garbage) before deciding whether to make streamed text
// authoritative. The streaming logic here is kept in sync with Sources/Parla/StreamingReconciler.swift,
// which is unit-tested; this harness is a dev tool (not shipped in the app).
//
// Usage: swift run ParlaStreamEval <samples-dir> <reference-md> <model> [lang=ru]

// MARK: - args

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: ParlaStreamEval <samples-dir> <reference-md> <model> [lang=ru] [thresholds] [offlineonly]\n".utf8))
    exit(2)
}
let samplesDir = args[1]
let referenceMD = args[2]
let model = args[3]
let language = args.count >= 5 ? args[4] : "ru"
// [thresholds] (6th arg): apply Whisper's anti-hallucination decoding thresholds (noSpeech / logProb /
// compressionRatio) — suppresses the "Спасибо"-on-silence garbage. Off by default to measure the baseline.
let useThresholds = args.contains("thresholds") || (args.count >= 6 && args[5] == "1")
// [offlineonly]: skip the streaming simulation → a fast model-vs-model OFFLINE WER A/B (the transcription-quality
// epic's model-tier gate). Streaming re-decodes ~26 windows/file, far too slow to compare two models on a set.
let offlineOnly = args.contains("offlineonly")

/// Decoding options, optionally with the anti-hallucination thresholds applied (the same knobs the app would set).
func decodeOpts() -> DecodingOptions {
    var o = DecodingOptions(task: .transcribe, language: language, detectLanguage: false)
    if useThresholds {
        o.compressionRatioThreshold = 2.4   // repetitive/looping output → fallback
        o.logProbThreshold = -1.0           // very low-confidence tokens → drop/fallback
        o.noSpeechThreshold = 0.6           // high no-speech prob → treat as silence (kills trailing hallucinations)
    }
    return o
}

// MARK: - ffmpeg (bundled, for Ogg/Opus → wav)

func resolveFFmpeg() -> String {
    let cwd = FileManager.default.currentDirectoryPath
    let candidates = [
        cwd + "/Parla.app/Contents/Resources/Helpers/ffmpeg",
        cwd + "/Vendor/ffmpeg/bin/ffmpeg",
    ]
    for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
    return "/usr/bin/env"   // fall back to PATH ffmpeg (arguments prefixed below)
}
let ffmpeg = resolveFFmpeg()

func toWav16k(_ input: String) throws -> String {
    let out = NSTemporaryDirectory() + "streameval-\(UUID().uuidString).wav"
    let p = Process()
    if ffmpeg == "/usr/bin/env" {
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["ffmpeg", "-y", "-i", input, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", out]
    } else {
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-y", "-i", input, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", out]
    }
    p.standardError = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: out) else {
        throw NSError(domain: "ffmpeg", code: Int(p.terminationStatus))
    }
    return out
}

// MARK: - reference transcripts (## filename \n text…)

func parseReferences(_ path: String) -> [String: String] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var refs: [String: String] = [:]
    var current: String?
    var buffer: [String] = []
    func flush() {
        if let c = current {
            refs[c] = buffer.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        buffer = []
    }
    for line in text.components(separatedBy: .newlines) {
        if line.hasPrefix("## ") {
            flush()
            current = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("#") || line.hasPrefix("---") || line.hasPrefix(">") {
            flush(); current = nil
        } else if current != nil {
            buffer.append(line)
        }
    }
    flush()
    return refs
}

// MARK: - text normalisation + WER

func stripTokens(_ s: String) -> String {
    // Remove Whisper special tokens <|...|> (mirrors stripWhisperTokens in the app).
    let r = s.replacingOccurrences(of: "<\\|[^>]*\\|>", with: "", options: .regularExpression)
    return r.trimmingCharacters(in: .whitespacesAndNewlines)
}

func words(_ s: String) -> [String] {
    let lowered = s.lowercased()
    var out = ""
    for scalar in lowered.unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) { out.unicodeScalars.append(scalar) }
        else { out.append(" ") }
    }
    return out.split(separator: " ").map(String.init)
}

/// Word-level error rate (Levenshtein over word sequences) of `hyp` against `ref`.
func wer(hyp: String, ref: String) -> Double {
    let h = words(hyp), r = words(ref)
    if r.isEmpty { return h.isEmpty ? 0 : 1 }
    if h.isEmpty { return 1 }
    var dp = Array(0...h.count)
    for i in 1...r.count {
        var prev = dp[0]
        dp[0] = i
        for j in 1...h.count {
            let tmp = dp[j]
            dp[j] = (r[i - 1] == h[j - 1]) ? prev : (min(prev, dp[j], dp[j - 1]) + 1)
            prev = tmp
        }
    }
    return Double(dp[h.count]) / Double(r.count)
}

// MARK: - streaming simulation (mirrors StreamingReconciler + the orchestrator window logic)

let kRate = 16_000.0
let kInterval = Int(1.5 * kRate)     // tick cadence
let kMinW = 12_000                   // 0.75 s — skip shorter windows
let kMaxW = 240_000                  // 15 s — hard window clamp
let kFlushSpan = 10.0                // s — force-flush threshold
let kHoldback = 2

func mergeDedup(_ base: String, _ addition: String) -> String {
    if addition.isEmpty { return base }
    if base.isEmpty { return addition }
    let addWords = addition.split(separator: " ")
    if let lastBase = base.split(separator: " ").last, lastBase == addWords.first {
        let kept = addWords.dropFirst()
        return kept.isEmpty ? base : base + " " + kept.joined(separator: " ")
    }
    return base + " " + addition
}

func joinSegs(_ segs: ArraySlice<TranscriptionSegment>) -> String {
    segs.map { stripTokens($0.text) }.filter { !$0.isEmpty }.joined(separator: " ")
}

func simulateStream(_ floats: [Float], kit: WhisperKit) async throws -> String {
    func decode(_ window: [Float]) async throws -> [TranscriptionSegment] {
        let r: [TranscriptionResult] = try await kit.transcribe(audioArray: window, decodeOptions: decodeOpts())
        return r.flatMap { $0.segments }
    }

    var confirmedText = ""
    var confirmedSeconds = 0.0
    let total = floats.count

    func ingest(_ segs: [TranscriptionSegment], windowStart: Double, flush: Bool) {
        let hb = flush ? 0 : kHoldback
        let confirmCount = max(0, segs.count - hb)
        let confirmed = segs.prefix(confirmCount)
        if let last = confirmed.last {
            confirmedText = mergeDedup(confirmedText, joinSegs(confirmed))
            confirmedSeconds = windowStart + Double(last.end)
        }
    }

    var nowSamples = kMinW
    while true {
        let liveCount = min(nowSamples, total)
        let cursorSample = Int(confirmedSeconds * kRate)
        let from = max(cursorSample, liveCount - kMaxW)
        if liveCount - from >= kMinW {
            let window = Array(floats[from..<liveCount])
            let segs = try await decode(window)
            let windowStart = Double(from) / kRate
            let atEnd = liveCount >= total
            let flush = atEnd || Double(window.count) / kRate >= kFlushSpan
            ingest(segs, windowStart: windowStart, flush: flush)
        }
        if liveCount >= total { break }
        nowSamples += kInterval
    }
    return confirmedText
}

// MARK: - run

func loadModel() async throws -> WhisperKit {
    let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
    let folder = root.appendingPathComponent(model, isDirectory: true)
    if FileManager.default.fileExists(atPath: folder.path) {
        return try await WhisperKit(WhisperKitConfig(model: model, modelFolder: folder.path, download: false))
    }
    return try await WhisperKit(WhisperKitConfig(model: model))
}

func offlineText(_ floats: [Float], kit: WhisperKit) async throws -> String {
    let r: [TranscriptionResult] = try await kit.transcribe(audioArray: floats, decodeOptions: decodeOpts())
    return r.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
}

let refs = parseReferences(referenceMD)
let files = ((try? FileManager.default.contentsOfDirectory(atPath: samplesDir)) ?? [])
    .filter { $0.hasSuffix(".ogg") || $0.hasSuffix(".wav") || $0.hasSuffix(".m4a") || $0.hasSuffix(".mp3") }
    .sorted()

print("model=\(model)  lang=\(language)  thresholds=\(useThresholds ? "ON" : "off")\(offlineOnly ? "  OFFLINE-ONLY" : "")  files=\(files.count)\n")

let kit = try await loadModel()

var offSum = 0.0, strSum = 0.0, n = 0
var offTimeSum = 0.0, strTimeSum = 0.0, durSum = 0.0
for file in files {
    let path = samplesDir + "/" + file
    do {
        let wav = (file.hasSuffix(".wav")) ? path : try toWav16k(path)
        let floats = try AudioProcessor.loadAudioAsFloatArray(fromPath: wav)
        let dur = Double(floats.count) / kRate

        let offStart = Date()
        let offline = try await offlineText(floats, kit: kit)
        let offTime = Date().timeIntervalSince(offStart)
        var streamed = "", strTime = 0.0
        if !offlineOnly {
            let strStart = Date()
            streamed = try await simulateStream(floats, kit: kit)
            strTime = Date().timeIntervalSince(strStart)
        }
        let ref = refs[file] ?? ""

        let offWER = ref.isEmpty ? Double.nan : wer(hyp: offline, ref: ref)
        let strWER = (ref.isEmpty || offlineOnly) ? Double.nan : wer(hyp: streamed, ref: ref)
        if !offWER.isNaN { offSum += offWER; strSum += strWER.isNaN ? 0 : strWER; n += 1 }
        offTimeSum += offTime; strTimeSum += strTime; durSum += dur

        func pct(_ x: Double) -> String { x.isNaN ? "  n/a" : String(format: "%5.1f%%", x * 100) }
        // RTF = decode time / audio length. <1 = faster than real time. Streamed re-decodes overlapping windows,
        // so its total compute is higher (that's the "RU is slow" cost we're quantifying).
        print("── \(file)  (\(String(format: "%.1f", dur))s)")
        print("   offline  WER \(pct(offWER))   \(String(format: "%.1fs (%.2f× RT)", offTime, offTime / dur))")
        if offlineOnly {
            print("   [offline] \(offline)")
        } else {
            print("   streamed WER \(pct(strWER))   Δ \(offWER.isNaN ? "n/a" : String(format: "%+.1f pts", (strWER - offWER) * 100))   \(String(format: "%.1fs (%.2f× RT)", strTime, strTime / dur))")
            print("   [streamed] \(streamed)")
        }
        print("")
    } catch {
        print("── \(file)  ERROR: \(error)\n")
    }
}

if n > 0 {
    print("════ AVERAGE over \(n) files (model=\(model), thresholds=\(useThresholds ? "ON" : "off")) ════")
    print(String(format: "   offline  WER %5.1f%%   %.2f× RT", offSum / Double(n) * 100, offTimeSum / durSum))
    if !offlineOnly {
        print(String(format: "   streamed WER %5.1f%%   Δ %+.1f pts   %.2f× RT", strSum / Double(n) * 100, (strSum - offSum) / Double(n) * 100, strTimeSum / durSum))
    }
}
