#if os(iOS)
import AudioToolbox

/// iOS completion cue — the counterpart of the macOS `CompletionSound` (NSSound "Glass"/"Basso"). Plays through
/// the system sound server (`AudioServicesPlaySystemSound`), which emits a short tone independent of the app's
/// AVAudioSession, so it works after a background transcription OR a dictation finishes. An unknown SystemSoundID
/// is a safe no-op. Wired via `AppModel.iOS()` and gated by the user's `soundOnComplete` toggle (default on, like
/// macOS). (Full-review D1/F2 — the seam was unwired, so the Settings toggle was a dead control on iOS.)
///
/// The exact SystemSoundIDs (a light positive tick for success, a distinct lower tone for failure) are tunable
/// and tunable to taste.
enum CompletionSound {
    static func success() { AudioServicesPlaySystemSound(1057) }   // "Tink" — light, positive
    static func failure() { AudioServicesPlaySystemSound(1053) }   // distinct lower alert tone
}
#endif
