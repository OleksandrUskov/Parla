import Foundation

/// Pure monetization policy (Branch 1 / Phase 3) — no StoreKit, no UI, so it's fully unit-testable and the
/// single place the free/Pro rules live. `PurchaseManager` owns the *entitlement* (`isPro`); this owns the
/// *rules* that entitlement gates.
///
/// Model (locked): freemium, one-time "buy-forever" Pro (non-consumable, NO subscription), server-less.
/// FREE = transcription up to `freeLimitSec` per file; PRO = unlimited length + the power/AI feature set.
public enum ProGate {
    /// StoreKit product identifier for the one-time Pro unlock.
    ///
    /// ⚠️ PLACEHOLDER in the `com.parla.*` namespace — used only by the LOCAL `.storekit` testing config today.
    /// The real App Store product is registered later, in the app's final reserved bundle namespace (flipped
    /// alongside the bundle IDs). A product ID is IMMUTABLE once created in App Store Connect, so this
    /// placeholder is NEVER registered as-is.
    public static let proProductID = "com.parla.pro.lifetime"

    /// Free-tier per-file transcription length cap, in seconds (owner: 5 minutes). The gate is a stateless
    /// per-file check (read the file's duration locally) — nothing is counted or persisted, which is what keeps
    /// the whole monetization server-less. Tunable post-launch.
    public static let freeLimitSec: Double = 5 * 60

    /// Whether a file's transcription must be gated behind Pro: a non-Pro user whose file runs LONGER than the
    /// free cap. Pro is always unlimited; a file exactly at the cap is still free ("up to 5 minutes" is
    /// inclusive). A non-positive / unknown duration never gates (we don't block what we can't measure).
    public static func exceedsFreeLimit(durationSec: Double, isPro: Bool) -> Bool {
        guard !isPro, durationSec > 0 else { return false }
        return durationSec > freeLimitSec
    }
}

/// Why the paywall is being presented — set by the gate, observed by the UI (which presents the paywall and
/// clears this on dismiss). `Identifiable` so it drives a `.sheet(item:)`. Grows more cases as feature gating
/// expands (e.g. a locked Pro-only feature).
public enum PaywallReason: Equatable, Sendable, Identifiable {
    /// A free user tried to transcribe a file longer than `ProGate.freeLimitSec`. Carries the file name + its
    /// length so the upsell can say "This 12-minute recording needs Pro".
    case lengthExceeded(fileName: String, durationSec: Double)

    public var id: String {
        switch self { case .lengthExceeded(let name, let dur): return "length:\(name):\(Int(dur))" }
    }
}
