import Foundation
@preconcurrency import UserNotifications   // UNNotificationSettings isn't Sendable on the Xcode 16.x SDK (Swift 6.1)

/// Thin wrapper over UNUserNotificationCenter + a pure (testable) "should we notify" decision.
///
/// The decision and text live in pure `static` functions with no system calls — they're unit-tested.
/// Only `post(...)` touches the system, and only from the real bundle (never called in tests).
public enum BatchNotifier {
    /// A single file shorter than this threshold won't post a notification (no spam on 3-sec voice memos).
    public static let singleFileThreshold: TimeInterval = 20

    /// Whether to notify: only if the job «was worth the wait» AND the window isn't frontmost.
    /// - Parameters:
    ///   - total: files in the job; elapsed: total time; frontmost: whether the Parla window is active.
    public static func shouldNotify(total: Int, elapsed: TimeInterval, frontmost: Bool) -> Bool {
        if frontmost { return false }            // user is already looking at the chip
        if total >= 2 { return true }            // any batch is worth a notification
        return elapsed >= singleFileThreshold    // single file — only if it took a while
    }

    /// Notification title + body (pure, testable).
    public static func summary(succeeded: Int, failed: Int) -> (title: String, body: String) {
        let total = succeeded + failed
        if succeeded == 0 {
            return ("Parla", Lf("notify.allfailed", total))
        }
        if failed == 0 {
            return ("Parla", Lf("notify.done", succeeded, transcriptionsWord(succeeded)))
        }
        return ("Parla", Lf("notify.partial", succeeded, total, failed))
    }

    /// Request permission lazily (on the first real send) and deliver the notification.
    /// Best-effort: on denial/unavailability it bails silently — the primary readiness signal is the in-window chip.
    @MainActor
    public static func post(succeeded: Int, failed: Int) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        var status = settings.authorizationStatus
        if status == .notDetermined {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            status = granted ? .authorized : .denied
        }
        guard status == .authorized || status == .provisional else { return }

        let (title, body) = summary(succeeded: succeeded, failed: failed)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: "parla.batch.\(UUID().uuidString)",
                                        content: content, trigger: nil)   // trigger:nil → deliver immediately
        try? await center.add(req)
    }
}
