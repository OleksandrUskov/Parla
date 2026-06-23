import KeyboardShortcuts

/// «Шов» горячей клавиши быстрой расшифровки.
///
/// Раньше здесь жил ручной NSEvent global+local монитор — он требовал «Универсального доступа»
/// (Accessibility) и слетал после каждой пере-сборки под ad-hoc подписью. Теперь — KeyboardShortcuts
/// (Carbon `RegisterEventHotKey`): переназначаемая комбинация, БЕЗ Accessibility и без системных
/// промптов. Регистрация обработчика и вкл/выкл — в `ParlaApp`; рекордер — в `SettingsView`.
///
/// ПРИВАТНОСТЬ: библиотека регистрирует ровно ОДНУ заданную комбинацию через Carbon — это НЕ
/// перехват и не лог нажатий (в отличие от мониторов ввода). Опционально, по умолчанию выключено.
extension KeyboardShortcuts.Name {
    /// Быстрая расшифровка аудиофайла из буфера. По умолчанию ⌃⌥⌘T; меняется в Настройках.
    static let quickTranscribe = Self("quickTranscribe",
                                      default: .init(.t, modifiers: [.control, .option, .command]))
}
