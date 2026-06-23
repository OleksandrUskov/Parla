import AppKit
import ApplicationServices

/// Чистая проверка совпадения комбинации (тестируемо без NSEvent).
/// Совпадение = тот же keyCode и все нужные модификаторы присутствуют (лишние — игнорируем).
func hotKeyMatches(keyCode: UInt16, flags: NSEvent.ModifierFlags,
                   wantKey: UInt16, wantMods: NSEvent.ModifierFlags) -> Bool {
    keyCode == wantKey &&
    flags.intersection(.deviceIndependentFlagsMask).isSuperset(of: wantMods)
}

/// Глобальный + локальный монитор горячей клавиши (⌃⌥⌘T по умолчанию).
/// Глобальный монитор требует «Универсального доступа» (Accessibility); локальный — нет,
/// поэтому комбинация работает хотя бы когда Parla активна, даже без разрешения.
/// Один файл-«шов»: чтобы перейти на rebindable-хоткей (KeyboardShortcuts), переписывается только он.
///
/// ПРИВАТНОСТЬ: `handle` лишь сверяет событие с одной комбинацией и игнорирует всё остальное —
/// нажатия НЕ логируются, не сохраняются и никуда не отправляются. Мониторы NSEvent в принципе
/// «только наблюдают» (не могут перехватывать/инжектить ввод). Включается опционально (по умолчанию выкл).
@MainActor
final class HotKeyMonitor {
    private var global: Any?
    private var local: Any?
    private let onTrigger: () -> Void

    // ⌃⌥⌘T : keyCode 17 = 'T'; модификаторы — control + option + command.
    private let keyCode: UInt16 = 17
    private let mods: NSEvent.ModifierFlags = [.control, .option, .command]

    init(onTrigger: @escaping () -> Void) { self.onTrigger = onTrigger }

    /// Идемпотентно: повторный вызов сначала снимает старые мониторы.
    func start() {
        stop()
        global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }     // вне приложения событие нельзя «съесть», только наблюдать
        }
        local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return e                                          // не блокируем ввод в самом приложении
        }
    }

    func stop() {
        if let g = global { NSEvent.removeMonitor(g); global = nil }
        if let l = local  { NSEvent.removeMonitor(l); local = nil }
    }

    private func handle(_ e: NSEvent) {
        if hotKeyMatches(keyCode: e.keyCode, flags: e.modifierFlags, wantKey: keyCode, wantMods: mods) {
            onTrigger()
        }
    }

    /// Доверен ли процесс для Accessibility (нужно для глобального монитора).
    static func isTrusted(prompt: Bool = false) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt]
        return AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }
}
