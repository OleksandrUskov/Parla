import XCTest
@testable import Parla_iOS

// iOS-port P1.3 runtime proof: decode a REAL Ogg/Opus (Telegram voice) fixture on the iOS simulator via the
// Opusfile-backed `OpusAudioDecoder` and assert the PCM is sane — link ≠ works ([[run-manual-verify-paths]]).
// The fixture is gitignored (voice never in git); when it's absent (CI / a fresh clone) the test XCTSkips, so
// it is never a false red. Run: xcodebuild test -scheme Parla-iOS -destination 'platform=iOS Simulator,name=iPhone 15'.
final class OpusDecodeTests: XCTestCase {

    func testDecodeRealOggOpusFixtureOnSimulator() throws {
        guard let url = Bundle(for: Self.self).url(forResource: "sample", withExtension: "ogg") else {
            throw XCTSkip("no local Ogg/Opus fixture bundled (gitignored) — skipping the runtime decode proof")
        }
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 0, "fixture is empty")

        let pcm = try XCTUnwrap(OpusAudioDecoder.decodeToMono48k(data), "Opusfile failed to decode the fixture")

        XCTAssertGreaterThan(pcm.count, 48_000, "expected > 1 s of 48 kHz PCM from a real voice note")
        XCTAssertTrue(pcm.prefix(48_000).allSatisfy { $0.isFinite && abs($0) <= 1.5 },
                      "decoded samples should be finite, in a plausible audio range")
        let seconds = Double(pcm.count) / 48_000
        print("✅ P1.3 decode proof: \(pcm.count) mono samples ≈ \(String(format: "%.1f", seconds)) s @ 48 kHz")
    }
}
