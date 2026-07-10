import ActivityKit
import ParlaCore

/// Drives the transcription Live Activity from the app (iOS-port P2.3b). Best-effort + additive: EVERY ActivityKit
/// call is wrapped so a disabled-authorization / throw can NEVER disrupt a transcription (mirrors the AI-layer
/// invariant). Wired from RootView via `.onChange(of: model.phase)` — the same observer seam as KeepAwake — so
/// Core stays untouched. Updates PER-CHUNK (a phase change carries the batch index); the system throttles Live
/// Activity updates, so we never push more often than the pipeline changes phase.
@MainActor
final class TranscriptionActivityController {
    private var activity: Activity<ParlaTranscriptionAttributes>?

    /// Map the engine phase → the activity. Start on the first transcription phase, update per-chunk, end on
    /// idle/failed. The standalone model DOWNLOAD is intentionally excluded (user default: transcription only).
    func sync(_ phase: EnginePhase) {
        switch phase {
        case .preparing(let name, let batch):
            upsert(label: L("la.preparing"), title: name, batch: batch)
        case .loadingModel:
            upsert(label: L("la.loadingmodel"), title: "", batch: nil)
        case .transcribing(let name, let batch):
            upsert(label: L("la.transcribing"), title: name, batch: batch)
        case .idle, .failed, .downloadingModel:
            end()
        }
    }

    private func upsert(label: String, title: String, batch: BatchProgress?) {
        let state = ParlaTranscriptionAttributes.ContentState(
            label: label, title: title,
            done: batch?.done ?? 0, total: batch?.total ?? 0)
        if let activity {
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }
        // Start a new activity — only if the user hasn't disabled Live Activities. Any throw is swallowed.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: ParlaTranscriptionAttributes(),
                content: ActivityContent(state: state, staleDate: nil))
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
