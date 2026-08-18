import SwiftUI
import ParlaCore

/// iOS app entry. Builds the real `AppModel.iOS()` (in-process decoder + UIKit seams + a
/// RAM-adaptive default model) once and injects it into the SwiftUI environment for the whole app.
@main
struct ParlaiOSApp: App {
    @State private var model: AppModel
    @State private var purchases = PurchaseManager()   // StoreKit-2 Pro entitlement (drives the free-tier gate + paywall)

    init() {
        // App.init is @MainActor-isolated → safe to build the @MainActor AppModel here.
        _model = State(initialValue: AppModel.iOS())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(purchases)
                .environment(\.locale, model.resolvedLocale)   // reading resolvedLocale here → re-render on language change (mirrors macOS scene root)
                .preferredColorScheme(.dark)   // Parla is dark-theme only, like the Mac app
                .task {
                    ParlaRuntime.model = model         // app-bound App Intents (Siri/Shortcuts) reach the live model
                    // On iPhone this is not housekeeping: the process has a hard memory budget and jetsam kills
                    // without warning, so handing the transcription weights back when the OS asks is survival.
                    model.startMemoryPressureMonitor()
                    // 🔴 The three launch steps macOS has always run and iOS never did. The visible one is the
                    // last: `refreshSemanticIndex` is the ONLY thing that fills the lemma and embedding indexes,
                    // both of which start empty and live in memory — so on iOS the Pro "Related" list was blank
                    // and Russian/Ukrainian morphology search fell back to substring matching after every cold
                    // launch, until the user happened to transcribe something.
                    await model.pruneAudioCache()      // orphans a crash left behind; the per-job prune misses those
                    await model.refreshModels()        // otherwise the manager only ever shows the hardcoded seed
                    Task { await model.refreshSemanticIndex() }
                    // NOT mirrored from macOS: `prewarmDictationModel`. Loading the weights at launch to make
                    // the first dictation instant is a good trade on a Mac and a bad one against a phone's
                    // memory budget, where the cost is a jetsam kill of the whole app.
                }
        }
    }
}

/// First-run gate: show the 4.2.3 model-download screen until the user downloads (or defers), then the main UI.
/// Keeps the display awake while any job is in flight (model download or transcription) — a long on-device run
/// must survive the screen not locking.
private struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(PurchaseManager.self) private var purchases
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("didOnboardIOS") private var didOnboard = false
    @AppStorage("didFirstRunSetup") private var didFirstRun = false
    // Held here (above RootTabView's `.id(uiLanguage)` swap) so the selected tab survives a language switch.
    @State private var tab: RootTab = .history
    // Drives the transcription Live Activity from the phase stream — best-effort, Core untouched.
    @State private var activityController = TranscriptionActivityController()

    var body: some View {
        Group {
            if !didOnboard {
                OnboardingView(onDone: { didOnboard = true })   // intro + privacy, then the model-download gate
            } else if didFirstRun {
                RootTabView(selection: $tab)
            } else {
                FirstRunDownloadView(onDone: { didFirstRun = true })
            }
        }
        .keepAwake(while: model.isBusy)
        // …and if the user leaves anyway (a call, another app), ask for a grace window so the chunk in flight
        // reaches disk instead of being cut off. Pairs with the resume record — see BackgroundGrace.
        .backgroundGrace(while: model.isBusy)
        .parlaToast()   // dictation + batch feedback surface (macOS QuickToast counterpart)

        // Pro entitlement: wire the live isPro into the free-tier gate + start StoreKit (load product,
        // resolve the current entitlement, listen for Transaction.updates). Idempotent.
        .task {
            // Freemium gate + StoreKit, only in a store build; a from-source build stays FULL. One call, in
            // Core, because it is testable there and was not testable here. (On iOS every share drains straight
            // into transcribe, so the wait-for-fact half of this matters on the very first cold launch.)
            model.installStoreGate(purchases)
        }
        // Free-tier length gate → up-front paywall (presents when the gate sets paywallReason; cleared on dismiss).
        .sheet(item: Binding(get: { model.paywallReason }, set: { model.paywallReason = $0 })) { reason in
            PaywallView(reason: reason)
                .environment(purchases)
                .environment(\.locale, model.resolvedLocale)
        }

        // Pick up anything the Share Extension dropped in the App Group inbox — on cold launch and every
        // foreground. Gated on didFirstRun so a shared file waits for the model-download gate instead of
        // failing to transcribe with no weights.
        .task { drainShareInbox() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { drainShareInbox() } }
        // Reflect the transcription pipeline in a Live Activity / Dynamic Island (best-effort; same observer seam
        // as KeepAwake, so Core is untouched). A phase change carries the batch index → per-chunk updates.
        .onChange(of: model.phase) { _, phase in activityController.sync(phase) }
        // Keep the Home-widget App-Group snapshot fresh: on launch and on every history change (add/delete/edit/
        // retitle — TranscriptItem is Hashable so `.onChange` catches them all). A no-op if the App Group is nil.
        .task { WidgetSnapshotWriter.write(from: model.history) }
        .onChange(of: model.history) { _, history in WidgetSnapshotWriter.write(from: history) }
        // parla:// deep-links (widget taps, Shortcuts, later Handoff). The pure parser lives in Core; here we
        // just route the verbs iOS supports. A note opens via `pendingOpen` (the History shell drains it), so it
        // works on both the compact and the split shell without either needing to know about URLs.
        .onOpenURL { url in
            switch parseParlaURL(url) {
            case .note(let id):  model.pendingOpen = id; tab = .history
            case .dictate:       model.toggleDictation(); tab = .history
            case .show:          tab = .history
            default:             break   // desktop-only verbs (transcribe / clipboard / last) — no-op on iOS
            }
        }
        // Handoff: continue a transcript opened on another device. Routes through pendingOpen (the History
        // shell drains it, incl. on cold launch via `.task`) → works on both the compact and split shells.
        .onContinueUserActivity(AppModel.viewTranscriptActivityType) { activity in
            model.continueViewTranscript(activity.userInfo)
            tab = .history
        }
    }

    private func drainShareInbox() {
        guard didFirstRun else { return }
        ShareInbox.drain(into: model)
    }
}
