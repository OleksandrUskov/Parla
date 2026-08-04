import XCTest
import AVFoundation
import ParlaCore

// runtime proof: exercise the REAL `AudioDecoding` seam (`OpusAudioDecoder` in ParlaCore) on a
// real Ogg/Opus fixture on the iOS simulator, and assert it yields a WAV WhisperKit can read — link ≠
// works ([[run-manual-verify-paths]]). A real Telegram voice note stays gitignored (voice never in git), so the
// target also bundles a committed synthetic tone and the test falls back to it — it RUNS everywhere, never skips.
// Run: xcodebuild test -scheme Parla-iOS -destination 'platform=iOS Simulator,id=<iPhone-15/iOS-17>'.
final class OpusDecodeTests: XCTestCase {

    /// Prefer a REAL (gitignored) Telegram voice note when the developer has one; otherwise fall back to the
    /// committed synthetic tone. Before that fallback existed this test simply XCTSkipped in CI and on any fresh
    /// clone — i.e. the native decode path, the entire point of Phase 2c, was automatically proven NOWHERE.
    private func oggFixture() throws -> URL {
        let bundle = Bundle(for: Self.self)
        if let real = bundle.url(forResource: "sample", withExtension: "ogg") { return real }
        return try XCTUnwrap(bundle.url(forResource: "tone", withExtension: "ogg"),
                             "no Ogg fixture bundled — Tests/ParlaTests/Fixtures/tone.ogg must be a resource of this target")
    }

    func testDecodeRealOggOpusFixtureViaSeam() throws {
        let url = try oggFixture()

        let wav = try OpusAudioDecoder().decodeToWav16k(url)
        defer { try? FileManager.default.removeItem(at: wav) }

        // The seam's contract: a WAV the engine (WhisperKit via AVAudioFile) can open. Verify it opens + is mono + non-trivial.
        let file = try AVAudioFile(forReading: wav)
        XCTAssertEqual(file.fileFormat.channelCount, 1, "decoder must yield mono")
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        XCTAssertGreaterThan(seconds, 1, "expected > 1 s of audio from a real voice note")
        print("✅ seam decode: \(file.length) frames @ \(Int(file.fileFormat.sampleRate)) Hz "
              + "≈ \(String(format: "%.1f", seconds)) s, ch=\(file.fileFormat.channelCount)")
    }

    // Regression: `renderPlayableWav` must produce an AVAudioPlayer-playable rendition for an
    // imported Telegram Ogg/Opus (it used to `throw .noDecoderAvailable`, so `AudioStore.makePlayable` returned nil
    // and in-app playback was a silent no-op on iOS while macOS played the same import). Fixture-gated like above.
    func testRenderPlayableWavYieldsAPlayableRendition() throws {
        let url = try oggFixture()
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
