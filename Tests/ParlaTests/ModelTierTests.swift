import XCTest
@testable import ParlaCore

/// the pure RAM-adaptive model-tier mapping. The live `os_proc_available_memory()` read is
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

    func testSizeEstimateDistinguishesTiers() {
        let turbo = ModelTierSelector.sizeEstimate(for: ModelTierSelector.turbo626)
        let small = ModelTierSelector.sizeEstimate(for: ModelTierSelector.small)
        let base = ModelTierSelector.sizeEstimate(for: ModelTierSelector.base)
        let tiny = ModelTierSelector.sizeEstimate(for: "openai_whisper-tiny")
        let large = ModelTierSelector.sizeEstimate(for: "openai_whisper-large-v3")
        // The 626 MB turbo must NOT be mistaken for the full large-v3 (guards the order-of-checks).
        XCTAssertNotEqual(turbo, large)
        // Each tier maps to a distinct size string/key (robust whether or not L() resolves in the test bundle).
        XCTAssertEqual(Set([turbo, small, base, tiny, large]).count, 5)
    }
}
