import Foundation

/// Pure, testable voice-activity gate for dictation auto-stop. Fed each audio buffer's loudness (RMS),
/// it decides when a run of silence — AFTER the user has actually spoken — should end the recording, so
/// a dictation stops itself when you stop talking. No audio types here → fully unit-testable; the live RMS
/// hook lives in `MicRecorder` / `WavSink`. Params are fixed v1 constants (tune by ear; expose later).
public struct SilenceDetector {
    /// RMS at/below this counts as silence. ~0.012 ≈ -38 dBFS for Float32 (-1…1) samples.
    public var threshold: Float
    /// Continuous silence (seconds) that ends the recording.
    public var silenceToStop: Double
    /// Require at least this much speech before arming — so it can't fire during the lead-in before you talk.
    public var minSpeechToArm: Double

    private var spokeFor: Double = 0    // total speech seconds so far (arms the detector once past minSpeechToArm)
    private var silentFor: Double = 0   // current run of continuous-silence seconds

    public init(threshold: Float = 0.012, silenceToStop: Double = 1.6, minSpeechToArm: Double = 0.4) {
        self.threshold = threshold
        self.silenceToStop = silenceToStop
        self.minSpeechToArm = minSpeechToArm
    }

    /// Feed one buffer's RMS over `dt` real-time seconds. Returns true EXACTLY when accumulated silence
    /// (after enough speech) first crosses the stop threshold → the caller should auto-stop. Renewed speech
    /// resets the silence run.
    mutating func feed(rms: Float, dt: Double) -> Bool {
        guard dt > 0 else { return false }
        if rms > threshold {
            spokeFor += dt
            silentFor = 0
            return false
        }
        guard spokeFor >= minSpeechToArm else { return false }   // not armed yet — no real speech seen
        silentFor += dt
        return silentFor >= silenceToStop
    }
}
