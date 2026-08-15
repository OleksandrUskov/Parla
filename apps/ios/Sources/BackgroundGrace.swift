import SwiftUI
import UIKit

/// Ask iOS not to suspend us the instant a running job goes to the background.
///
/// `keepAwake` handles the screen locking itself; this handles the other way work is lost — the user switching
/// to another app, or answering a call. A backgrounded app is suspended within a few seconds unless it holds a
/// background-task assertion, and a suspension mid-chunk is a chunk's worth of inference thrown away.
///
/// Be precise about what this buys, because it is easy to overclaim: an assertion is a SHORT grace window
/// (tens of seconds, at the system's discretion), not permission to keep running. A 40-minute transcription
/// will not finish in the background, and no honest app can make it — the `audio` background mode exists for
/// playing and recording audio, and claiming it to run inference would be a misuse and a review risk. What the
/// window is actually for is letting the chunk in flight finish and its result reach disk, which the resume
/// record then picks up on the next launch. Grace plus persistence is the whole mechanism; neither half is
/// sufficient alone.
///
/// The expiry handler is not optional: iOS terminates an app that still holds an assertion when the window
/// closes. Ending it there means the app is suspended normally, with the completed chunks already written.
private struct BackgroundGraceModifier: ViewModifier {
    let active: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var task: UIBackgroundTaskIdentifier = .invalid

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                // Only ask when leaving the foreground WITH work in flight. Holding an assertion the rest of the
                // time would spend the app's background budget on nothing and is exactly what iOS penalises.
                if phase != .active, active { begin() } else { end() }
            }
            .onChange(of: active) { _, running in
                if !running { end() }          // the job finished while backgrounded → release immediately
            }
            .onDisappear { end() }
    }

    private func begin() {
        guard task == .invalid else { return }   // single-flight: a second assertion would leak the first
        task = UIApplication.shared.beginBackgroundTask(withName: "parla.transcription") {
            end()                                 // the window closed — release, or iOS kills the app outright
        }
    }

    private func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}

extension View {
    /// Hold a background-task assertion while `active` and the app is not foregrounded, so the unit of work in
    /// flight can finish and be persisted instead of being cut off. See `BackgroundGraceModifier` for what this
    /// does and does not promise.
    func backgroundGrace(while active: Bool) -> some View {
        modifier(BackgroundGraceModifier(active: active))
    }
}
