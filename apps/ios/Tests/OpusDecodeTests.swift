import XCTest
import AVFoundation
import ParlaCore

// iOS-port P1.3 runtime proof: exercise the REAL `AudioDecoding` seam (`OpusAudioDecoder` in ParlaCore) on a
// real Telegram Ogg/Opus fixture on the iOS simulator, and assert it yields a WAV WhisperKit can read — link ≠
// works ([[run-manual-verify-paths]]). The fixture is gitignored (voice never in git); when it's absent (CI / a
// fresh clone) the test XCTSkips, so it is never a false red.
// Run: xcodebuild test -scheme Parla-iOS -destination 'platform=iOS Simulator,id=<iPhone-15/iOS-17>'.
final class OpusDecodeTests: XCTestCase {

    func testDecodeRealOggOpusFixtureViaSeam() throws {
        guard let url = Bundle(for: Self.self).url(forResource: "sample", withExtension: "ogg") else {
            throw XCTSkip("no local Ogg/Opus fixture bundled (gitignored) — skipping the runtime decode proof")
        }

        let wav = try OpusAudioDecoder().decodeToWav16k(url)
        defer { try? FileManager.default.removeItem(at: wav) }

        // The seam's contract: a WAV the engine (WhisperKit via AVAudioFile) can open. Verify it opens + is mono + non-trivial.
        let file = try AVAudioFile(forReading: wav)
        XCTAssertEqual(file.fileFormat.channelCount, 1, "decoder must yield mono")
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        XCTAssertGreaterThan(seconds, 1, "expected > 1 s of audio from a real voice note")
        print("✅ P1.3 seam decode: \(file.length) frames @ \(Int(file.fileFormat.sampleRate)) Hz "
              + "≈ \(String(format: "%.1f", seconds)) s, ch=\(file.fileFormat.channelCount)")
    }

    // Full-review D1 F3 regression: `renderPlayableWav` must produce an AVAudioPlayer-playable rendition for an
    // imported Telegram Ogg/Opus (it used to `throw .noDecoderAvailable`, so `AudioStore.makePlayable` returned nil
    // and in-app playback was a silent no-op on iOS while macOS played the same import). Fixture-gated like above.
    func testRenderPlayableWavYieldsAPlayableRendition() throws {
        guard let url = Bundle(for: Self.self).url(forResource: "sample", withExtension: "ogg") else {
            throw XCTSkip("no local Ogg/Opus fixture bundled (gitignored) — skipping the playback-rendition proof")
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("parla-playable-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: dest) }

        try OpusAudioDecoder().renderPlayableWav(from: url, to: dest)

        // The contract AudioStore.makePlayable relies on: a file AVAudioPlayer can actually open (not the raw .ogg).
        let player = try AVAudioPlayer(contentsOf: dest)
        XCTAssertGreaterThan(player.duration, 1, "expected > 1 s of playable audio")
        let file = try AVAudioFile(forReading: dest)
        XCTAssertEqual(file.fileFormat.channelCount, 1, "rendition must be mono")
    }
}
