import Foundation
// @preconcurrency: AVSpeechSynthesizer's `write(_:toBufferCallback:)` takes a NON-@Sendable escaping callback
// that fires off-actor on its own queue (same class of hazard as the MicRecorder tap / WhisperKit progress).
// The import downgrades that Sendable-mismatch so v6 only flags OUR genuine isolation issues; we serialize the
// callback's state ourselves via an @unchecked Sendable Sink (the callback is invoked one buffer at a time).
@preconcurrency import AVFoundation

/// Availability of TTS for a given language (mirrors `AIAvailability` — the capability-gated seam pattern).
enum TTSAvailability: Equatable, Sendable {
    case ready          // ≥1 voice available for the language
    case unsupported    // no voice for this language
}

/// A synthesizable voice: a system `AVSpeechSynthesizer` voice today; (P1b) a downloaded preset later.
struct VoiceDescriptor: Identifiable, Hashable, Sendable {
    let id: String        // stable id — system: `AVSpeechSynthesisVoice.identifier`; (P1b) preset: catalogue id
    let name: String      // display name
    let language: String  // BCP-47, e.g. "ru-RU", "uk-UA", "en-US"
    let isSystem: Bool     // true for AVSpeechSynthesizer system voices (the zero-download floor)
}

enum TTSError: LocalizedError {
    case noVoice
    case synthesisFailed
    var errorDescription: String? {
        switch self {
        case .noVoice: return L("error.tts.novoice")
        case .synthesisFailed: return L("error.tts.failed")
        }
    }
}

/// One capability-gated seam over on-device TTS backends, mirroring `LocalLLMService` / `TranscribingEngine`:
/// a `Sendable` protocol with an injectable default on `AppModel`, a test double, and (P1b) a backend selector.
/// **TTS is ADDITIVE** — it never touches the transcript / `history.json` pipeline.
protocol TTSService: Sendable {
    func availability(forLanguage language: String) -> TTSAvailability
    func voices(forLanguage language: String) -> [VoiceDescriptor]
    /// Synthesize `text` in `voice` → a playable audio file on disk. The caller owns the file (plays + deletes).
    func synthesize(_ text: String, voice: VoiceDescriptor) async throws -> URL
}

/// Pure voice-filtering, split out so the language-matching logic is unit-testable without live system voices.
enum VoiceSelection {
    /// Voices whose language matches `language` by its 2-letter prefix ("ru" matches "ru-RU"). Empty → all.
    static func filter(_ voices: [VoiceDescriptor], language: String) -> [VoiceDescriptor] {
        let want = String(language.prefix(2)).lowercased()
        return want.isEmpty ? voices : voices.filter { $0.language.lowercased().hasPrefix(want) }
    }
}

// MARK: - System backend (AVSpeechSynthesizer — always available, zero download, mediocre)

/// TTS over `AVSpeechSynthesizer`. Always ready (RU=Milena, UK=Lesya, many EN on stock macOS). Runs synthesis
/// in an `actor` (only `Sendable` URLs cross back). This is the zero-download floor; P1b adds sherpa-onnx/Piper.
actor SystemTTSService: TTSService {
    /// All system voices as descriptors (thin adapter; the filtering itself is the pure `VoiceSelection`).
    nonisolated static func allVoices() -> [VoiceDescriptor] {
        AVSpeechSynthesisVoice.speechVoices().map {
            VoiceDescriptor(id: $0.identifier, name: $0.name, language: $0.language, isSystem: true)
        }
    }

    nonisolated func voices(forLanguage language: String) -> [VoiceDescriptor] {
        VoiceSelection.filter(Self.allVoices(), language: language)
    }

    nonisolated func availability(forLanguage language: String) -> TTSAvailability {
        voices(forLanguage: language).isEmpty ? .unsupported : .ready
    }

    func synthesize(_ text: String, voice: VoiceDescriptor) async throws -> URL {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TTSError.synthesisFailed }
        guard let avVoice = AVSpeechSynthesisVoice(identifier: voice.id) else { throw TTSError.noVoice }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parla-tts-\(UUID().uuidString).wav")
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = avVoice
        let synth = AVSpeechSynthesizer()

        // The write() callback fires off-actor, one buffer at a time, ending with a zero-length buffer. The Sink
        // (a) retains `synth` so it isn't deallocated mid-write, (b) holds the AVAudioFile writer, (c) guards a
        // single continuation resume. It's @unchecked Sendable because access is inherently serial (one buffer
        // at a time) — matches the FolderWatcher / test TaskBox pattern.
        final class Sink: @unchecked Sendable {
            let url: URL
            let synth: AVSpeechSynthesizer
            var file: AVAudioFile?
            var resumed = false
            init(url: URL, synth: AVSpeechSynthesizer) { self.url = url; self.synth = synth }
        }
        let sink = Sink(url: url, synth: synth)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            synth.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    // Terminal buffer: CLOSE the writer (nil → dealloc flushes the WAV header, else it reads
                    // back as 0 frames) BEFORE handing the URL back — the load-bearing fix from the spike.
                    sink.file = nil
                    if !sink.resumed { sink.resumed = true; cont.resume() }
                    return
                }
                do {
                    if sink.file == nil {
                        sink.file = try AVAudioFile(forWriting: sink.url, settings: pcm.format.settings)
                    }
                    try sink.file?.write(from: pcm)
                } catch {
                    sink.file = nil
                    if !sink.resumed { sink.resumed = true; cont.resume(throwing: error) }
                }
            }
        }

        // Empty/failed synthesis produces no readable audio → surface it instead of returning a junk file.
        guard let f = try? AVAudioFile(forReading: url), f.length > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw TTSError.synthesisFailed
        }
        return url
    }
}

// MARK: - Test double

/// No-op TTS for unit tests: reports a fixed availability + canned voices, never actually synthesizes.
struct NoopTTSService: TTSService {
    var availabilityToReturn: TTSAvailability = .unsupported
    var cannedVoices: [VoiceDescriptor] = []
    func availability(forLanguage language: String) -> TTSAvailability { availabilityToReturn }
    func voices(forLanguage language: String) -> [VoiceDescriptor] { VoiceSelection.filter(cannedVoices, language: language) }
    func synthesize(_ text: String, voice: VoiceDescriptor) async throws -> URL { throw TTSError.synthesisFailed }
}
