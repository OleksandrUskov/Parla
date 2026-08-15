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

    /// iOS ships only through the App Store, so this build is ALWAYS a store build — and unlike `swift test`,
    /// this suite is hosted inside the real app (`TEST_HOST = Parla-iOS.app`), so `Bundle.main` here is the
    /// shipping bundle. That makes this the one place the plist → flag path can be proven end to end rather
    /// than in pieces: it goes red if the key is deleted from `Parla-iOS-Info.plist`, retyped as a string the
    /// decode does not accept, or if the factory line rots — each of which ships an App Store build with no
    /// paywall, no length cap, everything Pro free, and zero revenue as the first and only symptom.
    func testShippingBundleIsAStoreBuild() {
        let raw = Bundle.main.object(forInfoDictionaryKey: AppModel.storeBuildInfoKey)
        XCTAssertNotNil(raw, "\(AppModel.storeBuildInfoKey) is missing from the app's Info.plist")
        XCTAssertTrue(AppModel.storeBuildFlag(raw), "the shipping bundle does not read as a store build")
        XCTAssertTrue(AppModel.iOS().isStoreBuild, "the iOS factory did not pick the flag up")
    }
}
