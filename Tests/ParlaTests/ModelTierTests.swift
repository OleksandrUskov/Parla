import XCTest
@testable import ParlaCore

/// iOS-port P1.4a — the pure RAM-adaptive model-tier mapping. The live `os_proc_available_memory()` read is
/// iOS-only, but the bytes→variant decision is cross-platform, so it's pinned here on macOS.
final class ModelTierTests: XCTestCase {

    func testRamAdaptiveDefaultModel() {
        // Roomy (≈8 GB): the same 626 MB turbo as Mac.
        XCTAssertEqual(ModelTierSelector.defaultModel(availableBytes: 4_000_000_000), ModelTierSelector.turbo626)
        XCTAssertEqual(ModelTierSelector.defaultModel(availableBytes: 2_600_000_000), ModelTierSelector.turbo626) // boundary
        // Mid (≈6 GB): small.
        XCTAssertEqual(ModelTierSelector.defaultModel(availableBytes: 2_000_000_000), ModelTierSelector.small)
        XCTAssertEqual(ModelTierSelector.defaultModel(availableBytes: 1_400_000_000), ModelTierSelector.small) // boundary
        // Floor (≈4 GB / while downloading): base.
        XCTAssertEqual(ModelTierSelector.defaultModel(availableBytes: 800_000_000), ModelTierSelector.base)
        XCTAssertEqual(ModelTierSelector.defaultModel(availableBytes: 0), ModelTierSelector.base)
    }

    func testAllTiersAreMultilingual() {
        // Parla's core is RU/UK Telegram voice — an `.en` tier must never be a default.
        for bytes: UInt64 in [0, 1_500_000_000, 3_000_000_000] {
            XCTAssertFalse(ModelTierSelector.defaultModel(availableBytes: bytes).contains(".en"))
        }
    }
}
