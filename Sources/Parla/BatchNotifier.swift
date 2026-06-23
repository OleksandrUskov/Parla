import Foundation
import UserNotifications

/// Тонкая обёртка над UNUserNotificationCenter + чистое (тестируемое) решение «слать ли уведомление».
///
/// Решение и текст вынесены в чистые `static`-функции без системных вызовов — они юнит-тестятся.
/// Систему трогает только `post(...)`, и только из реального бандла (в тестах никогда не вызывается).
enum BatchNotifier {
    /// Одиночный файл короче этого порога не шлёт уведомление (не спамим на 3-сек голосовых).
    static let singleFileThreshold: TimeInterval = 20

    /// Слать ли уведомление: только если задание «стоило ожидания» И окно не на переднем плане.
    /// - Parameters:
    ///   - total: файлов в задании; elapsed: суммарное время; frontmost: активно ли окно Parla.
    static func shouldNotify(total: Int, elapsed: TimeInterval, frontmost: Bool) -> Bool {
        if frontmost { return false }            // юзер и так смотрит на чип
        if total >= 2 { return true }            // любой батч достоин уведомления
        return elapsed >= singleFileThreshold    // одиночный файл — только если был долгим
    }

    /// Заголовок + тело уведомления (чисто, тестируемо).
    static func summary(succeeded: Int, failed: Int) -> (title: String, body: String) {
        let total = succeeded + failed
        if succeeded == 0 {
            return ("Parla", "Не удалось распознать (\(total))")
        }
        let word = pluralRu(succeeded, "расшифровка", "расшифровки", "расшифровок")
        if failed == 0 {
            return ("Parla", "Готово: \(succeeded) \(word)")
        }
        return ("Parla", "\(succeeded) из \(total) готово · \(failed) не удал\(failed == 1 ? "ась" : "ось")")
    }

    /// Запросить разрешение лениво (на первой реальной отправке) и доставить уведомление.
    /// Best-effort: при отказе/недоступности молча выходит — основной сигнал готовности это чип в окне.
    @MainActor
    static func post(succeeded: Int, failed: Int) async {
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
                                        content: content, trigger: nil)   // trigger:nil → доставка сразу
        try? await center.add(req)
    }
}
