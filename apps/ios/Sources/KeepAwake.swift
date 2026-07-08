import SwiftUI
import UIKit

/// Keep the display awake while a job is running (iOS-port P1.4f — long-audio robustness).
///
/// A long on-device transcription runs for minutes (a 70-min recording chunks into ~35 passes). If the screen
/// auto-locks, iOS suspends the app and the job is killed — or jetsam'd — mid-chunk, and the user loses the
/// whole run. Binding the idle timer to `isBusy` (transcription, model download, dictation recording) keeps the
/// device awake for the duration and restores the OS default the instant the work finishes. This is an
/// iOS-only concern (macOS has no idle timer), so it lives in the app target, not Core.
private struct KeepAwakeModifier: ViewModifier {
    let active: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: active) { _, on in
                UIApplication.shared.isIdleTimerDisabled = on
            }
            // iOS ignores the flag while backgrounded (the screen locks anyway); re-assert the correct state
            // when we return to the foreground so a still-running job keeps the device awake again.
            .onChange(of: scenePhase) { _, phase in
                UIApplication.shared.isIdleTimerDisabled = (phase == .active && active)
            }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

extension View {
    /// Prevent the display from sleeping while `active` (e.g. a multi-minute transcription) — see
    /// `KeepAwakeModifier`. The idle timer returns to the OS default the moment `active` flips false.
    func keepAwake(while active: Bool) -> some View {
        modifier(KeepAwakeModifier(active: active))
    }
}
