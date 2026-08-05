// @preconcurrency: ActivityKit is not Sendable-audited — its `.swiftinterface` gives `Activity<Attributes>` no
// Sendable conformance at all, while `update`/`end` are nonisolated `async`. So handing our activity to them from
// this @MainActor type reads as sending a non-Sendable value out of the actor's region, and a newer compiler than
// the one this was written on rejects it ("Sending 'activity' risks causing data races" — caught by CI on Xcode
// 26.6, invisible on 26.0). This is the same situation as WhisperKit and is silenced the same narrow way.
//
// Audited rather than waved through: the activity is created on the main actor and touched ONLY from Tasks that
// inherit main-actor isolation, so there is no second thread to race with. ActivityKit is documented as callable
// from any context. What is suppressed is the SDK's missing annotation, not a real concurrency hazard here.
@preconcurrency import ActivityKit
import Foundation
import ParlaCore

/// Drives the transcription Live Activity from the app. Best-effort + additive: EVERY ActivityKit
/// call is wrapped so a disabled-authorization / throw can NEVER disrupt a transcription (mirrors the AI-layer
/// invariant). Wired from RootView via `.onChange(of: model.phase)` — the same observer seam as KeepAwake — so
/// Core stays untouched. Updates PER-CHUNK (a phase change carries the batch index); the system throttles Live
/// Activity updates, so we never push more often than the pipeline changes phase.
@MainActor
final class TranscriptionActivityController {
    private var activity: Activity<ParlaTranscriptionAttributes>?

    /// How long an activity may go without an update before the system marks it stale. A transcription pushes a
    /// phase change per chunk, so silence for this long means the job is gone, not slow. Belt to the braces of
    /// the launch sweep below: it is what the Lock Screen falls back to if the process dies mid-job and the user
    /// does not reopen the app.
    private static let staleAfter: TimeInterval = 30 * 60

    /// End any activity left over from a PREVIOUS process. Nothing here ever read
    /// `Activity<…>.activities`, so a force-quit or a jetsam kill mid-transcription — which this codebase
    /// expects, see KeepAwake and ParlaiOSApp's own comments — left "Расшифровка… 3/35" frozen on the Lock
    /// Screen for the system's whole 8h window. Worse, the next launch started with `activity == nil`, so the
    /// next transcription requested a SECOND card beside the dead one, and repeated kills stacked them until
    /// ActivityKit's per-app limit made `request` throw and new transcriptions silently got no activity at all.
    /// A live activity cannot outlive its process by design here: no transcription survives a process death.
    init() {
        let orphans = Activity<ParlaTranscriptionAttributes>.activities
        guard !orphans.isEmpty else { return }
        Task { for a in orphans { await a.end(nil, dismissalPolicy: .immediate) } }
    }

    /// Map the engine phase → the activity. Start on the first transcription phase, update per-chunk, end on
    /// idle/failed. The standalone model DOWNLOAD is intentionally excluded (user default: transcription only).
    func sync(_ phase: EnginePhase) {
        switch phase {
        case .preparing(let name, let batch):
            upsert(label: L("la.preparing"), title: name, done: batch?.done ?? 0, total: batch?.total ?? 0)
        case .downloadingModel(let p):
            // A model download only ever happens INSIDE a transcription job (the standalone model-manager download
            // uses a separate mechanism, not this phase), so keep the activity ALIVE through it — ending here would
            // make it vanish during the LONGEST wait, then restart. Encode the 0…1 progress as done/total.
            upsert(label: L("la.downloadingmodel"), title: "", done: Int((p * 100).rounded()), total: 100)
        case .loadingModel:
            upsert(label: L("la.loadingmodel"), title: "", done: 0, total: 0)
        case .transcribing(let name, let batch):
            upsert(label: L("la.transcribing"), title: name, done: batch?.done ?? 0, total: batch?.total ?? 0)
        case .idle, .failed:
            end()
        }
    }

    private func upsert(label: String, title: String, done: Int, total: Int) {
        let state = ParlaTranscriptionAttributes.ContentState(label: label, title: title, done: done, total: total)
        if let activity {
            Task { await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))) }
            return
        }
        // Start a new activity — only if the user hasn't disabled Live Activities. Any throw is swallowed.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: ParlaTranscriptionAttributes(),
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter)))
        } catch {
            activity = nil   // best-effort: a failed request never disrupts the transcription
        }
    }

    private func end() {
        guard let a = activity else { return }
        activity = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }
}
