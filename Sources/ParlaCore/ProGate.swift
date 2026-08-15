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

    /// Consumable "tip the developer" product IDs (D3 tip-jar) — separate from Pro, grant NO entitlement.
    /// Placeholder namespace like `proProductID` (LOCAL `.storekit` only until the real ASC records exist).
    public static let tipProductIDs = ["com.parla.tip.small", "com.parla.tip.medium", "com.parla.tip.large"]

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

    /// Which export formats are Pro-only: the subtitle formats (SRT/VTT) + JSON. Plain TXT and Markdown stay
    /// free (the everyday "copy the text out" path). Pure, so it's the single testable source of the export split.
    public static func isProExportFormat(_ format: ExportFormat) -> Bool {
        switch format {
        case .txt, .markdown:   return false
        case .srt, .vtt, .json: return true
        }
    }

    // MARK: The paywall's promise

    /// Folder watching is FSEvents-based (`FolderWatcher`), which exists on macOS only — iOS has no equivalent
    /// and never will through this seam. Kept as ONE named constant instead of an `#if` inside the paywall so
    /// the bullet list below stays a pure function that a test can evaluate for BOTH platforms from a macOS
    /// test host. This single line is the only inch of the platform split that tests cannot execute.
    public static let platformHasFolderWatch: Bool = {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }()

    /// One paywall bullet, addressed by its localization key stem (`x` for the title, `x.detail` for the body).
    /// Carrying keys rather than resolved strings is what makes the promise testable: a test can assert both
    /// WHICH claims a platform makes and that every key behind them actually resolves in all three catalogues.
    public struct PaywallBullet: Identifiable, Sendable, Equatable {
        public let key: String       // localization key stem == the stable identity
        public let icon: String      // SF Symbol
        public var id: String { key }
        public var titleKey: String { key }
        public var detailKey: String { key + ".detail" }
        public init(key: String, icon: String) { self.key = key; self.icon = icon }
    }

    /// What Pro promises, in paywall order. `folderWatch` decides the batch bullet ONLY: with folder watching the
    /// bullet sells "batch + watched folder", without it just the queue — both of which the platform in question
    /// genuinely delivers (multi-file import and the queue gate are cross-platform; the watcher is not).
    ///
    /// This exists because an App Store paywall that sells a feature the app on THAT platform cannot perform is
    /// an accurate-metadata problem at review, and a broken promise to whoever pays anyway. The iOS purchase
    /// unlocks iOS: the bundle IDs differ, so there is no Universal Purchase carrying a Mac feature across.
    public static func paywallBullets(folderWatch: Bool) -> [PaywallBullet] {
        [
            .init(key: "paywall.feature.length",                            icon: "infinity"),
            .init(key: "paywall.feature.chapters",                          icon: "list.bullet.rectangle"),
            .init(key: folderWatch ? "paywall.feature.batch"
                                   : "paywall.feature.queue",               icon: "square.stack.3d.up"),
            .init(key: "paywall.feature.export",                            icon: "captions.bubble"),
            .init(key: "paywall.feature.ai",                                icon: "sparkles"),
        ]
    }
}

/// A Pro-only capability — carried by `PaywallReason.featureLocked` so the paywall can name what the user tapped.
/// Grows as feature gating expands (AI power…).
public enum ProFeature: String, Sendable, Equatable {
    case export        // advanced export: SRT / VTT / JSON
    case batch         // transcribing several files at once (a multi-file or folder drop / a second queued job)
    case folderWatch   // auto-transcribing a watched folder (macOS)
    case aiPower       // generative insights: MLX/embed download, manual ✨ regenerate, per-chapter summaries, Related
}

/// Why the paywall is being presented — set by the gate, observed by the UI (which presents the paywall and
/// clears this on dismiss). `Identifiable` so it drives a `.sheet(item:)`. Grows more cases as feature gating
/// expands (e.g. a locked Pro-only feature).
public enum PaywallReason: Equatable, Sendable, Identifiable {
    /// A free user tried to transcribe a file longer than `ProGate.freeLimitSec`. Carries the file name + its
    /// length so the upsell can say "This 12-minute recording needs Pro".
    case lengthExceeded(fileName: String, durationSec: Double)
    /// A free user tapped a Pro-only feature (e.g. SRT export).
    case featureLocked(ProFeature)

    public var id: String {
        switch self {
        case .lengthExceeded(let name, let dur): return "length:\(name):\(Int(dur))"
        case .featureLocked(let f):              return "feature:\(f.rawValue)"
        }
    }
}
