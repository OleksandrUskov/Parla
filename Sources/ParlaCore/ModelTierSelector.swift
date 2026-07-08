import Foundation

/// RAM-adaptive default WhisperKit variant (iOS-port P1.4a). On iOS the **jetsam ceiling** — not compute —
/// decides how big a model a device can hold, so the default is chosen at runtime from the process's
/// available-memory headroom (`os_proc_available_memory()`), not hardcoded like the Mac's 626 MB turbo.
///
/// This is the PURE, cross-platform mapping (bytes → variant), so it's unit-tested on macOS; the iOS layer
/// (`AppModel.iOS()`) reads the live headroom and passes it in. All tiers are **multilingual** — RU/UK Telegram
/// voice is Parla's core, so an `.en` tier is never selected. Thresholds are conservative (leave room for the
/// one-time ANE compile + audio buffers) and tunable as real-device numbers come in (IOS_PORT §3).
public enum ModelTierSelector {
    /// The same compressed 626 MB turbo Parla ships on Mac — near-Mac RU/UK quality; the roomy-device default.
    public static let turbo626 = "openai_whisper-large-v3-v20240930_626MB"
    public static let small = "openai_whisper-small"
    public static let base = "openai_whisper-base"

    /// Largest multilingual tier that comfortably fits `availableBytes` of process-memory headroom.
    public static func defaultModel(availableBytes: UInt64) -> String {
        switch availableBytes {
        case 2_600_000_000...: return turbo626   // ~8 GB devices (iPhone 15 Pro+/16/17): the Mac-grade model
        case 1_400_000_000...: return small      // ~6 GB (iPhone 14/15/15 Plus)
        default:               return base        // ~4 GB (SE) / while-downloading floor
        }
    }
}
