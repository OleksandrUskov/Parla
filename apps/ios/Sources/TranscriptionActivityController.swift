import ActivityKit
import ParlaCore

/// Drives the transcription Live Activity from the app. Best-effort + additive: EVERY ActivityKit
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
