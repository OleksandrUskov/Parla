import XCTest
@testable import Parla_iOS
import ParlaCore

// `AppModel.iOS()` factory proof. Closes the decode pipeline: it asserts the app factory
// injects the in-process `OpusAudioDecoder` (libopusfile + AVAssetReader) into the Core view-model's decode
// seam, so a real iOS `AppModel` can decode Ogg/Opus + mp4/mov/flac and chunk long audio — no ffmpeg.
@MainActor
final class AppModeliOSFactoryTests: XCTestCase {

    func testFactoryInjectsInProcessDecoder() {
        let model = AppModel.iOS()
        XCTAssertTrue(model.decoder is OpusAudioDecoder, "iOS factory must inject the in-process decoder seam")
        XCTAssertTrue(model.decoder.isChunkingAvailable, "the iOS decoder supports the chunked long-audio path")
    }
}
