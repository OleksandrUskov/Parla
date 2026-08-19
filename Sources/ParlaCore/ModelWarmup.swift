import Foundation

/// What to tell someone while a recognition model is being prepared — and how to stop lying to them about it.
///
/// ## The wait is real and it is not a hang
///
/// The first time a model is used on a device, Core ML compiles it for the Neural Engine. Measured on the
/// shipping 626 MB model: **431 seconds the first time, 10 seconds every time after** — and the compiled result
/// is cached per app container, so a sandboxed build inherits none of it. Seven minutes under a motionless
/// "Loading the model…" is indistinguishable from a frozen app, and it lands on the very first thing a new user
/// (or an App Review tester) does.
///
/// ## Why there is no percentage, and why inventing one would be worse
///
/// WhisperKit's `progressCallback` covers the DOWNLOAD only; the `WhisperKit(...)` initialiser, which is where
/// the compile happens, reports nothing at all. A percentage would therefore have to be guessed from a
/// hardcoded duration, and the hardware this runs on spans an M-series Mac and an iPhone — the guess would be
/// wrong by multiples, and a bar that sits at 99% is a worse experience than no bar. So: elapsed time, which is
/// true, plus a sentence explaining what the wait is for.
///
/// ## Warmth is per MODEL, which is what both platforms got wrong
///
/// The reassurance used to be gated on a single global `didCompileModel` flag, and the two apps then disagreed
/// in opposite directions: macOS showed it once per install and never again — so switching to a different
/// model, which pays the full compile again, got no explanation — while iOS showed it on *every* load, telling
/// someone their fiftieth ten-second load was a one-time first run. The honest unit is the model.
public enum ModelWarmup {

    /// Has this model already paid its first-compile cost on this device?
    public static func isWarm(_ model: String, warmed: Set<String>) -> Bool { warmed.contains(model) }

    /// Whether to explain the wait. Only for a model that has never finished loading here.
    public static func shouldExplainWait(for model: String, warmed: Set<String>) -> Bool {
        !model.isEmpty && !isWarm(model, warmed: warmed)
    }

    /// `m:ss` for a wait whose total is unknown — deliberately not a percentage.
    ///
    /// Past an hour it grows to `h:mm:ss` rather than showing "83:20", which reads as nonsense. Negative and
    /// non-finite inputs clamp to zero: a clock jump must not produce a countdown or a crash.
    public static func elapsedLabel(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? Int(max(0, seconds)) : 0
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Whether the clock is worth showing yet.
    ///
    /// A warm load takes about ten seconds, and a timer flickering "0:02" on it is noise. The point of the
    /// clock is the cold load, where the alternative is a motionless label for several minutes — so it appears
    /// only once the wait has gone on long enough that a user has started to wonder.
    public static func shouldShowElapsed(_ seconds: TimeInterval) -> Bool { seconds.isFinite && seconds >= 5 }

    /// The set to start from when upgrading an install that only ever had the old global boolean.
    ///
    /// Someone whose flag was already true has a warm model — the one they were using — and must not be told
    /// "this happens once" on their next load. Nothing is claimed about any OTHER model, which is precisely the
    /// improvement: the next one they try will explain itself, as it should have all along.
    public static func migratedWarmSet(legacyDidCompile: Bool, currentModel: String) -> Set<String> {
        legacyDidCompile && !currentModel.isEmpty ? [currentModel] : []
    }
}
