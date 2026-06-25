import KeyboardShortcuts

/// The hot-key «seam» for quick transcription.
///
/// This used to be a manual NSEvent global+local monitor — it required Accessibility
/// («Universal Access») and broke after every rebuild under an ad-hoc signature. Now it's KeyboardShortcuts
/// (Carbon `RegisterEventHotKey`): a rebindable combo, WITHOUT Accessibility and without system
/// prompts. Handler registration and enable/disable live in `ParlaApp`; the recorder lives in `SettingsView`.
///
/// PRIVACY: the library registers exactly ONE specified combo via Carbon — this is NOT
/// keystroke interception or logging (unlike input monitors). Optional, disabled by default.
extension KeyboardShortcuts.Name {
    /// Quick transcription of an audio file from the clipboard. Defaults to ⌃⌥⌘T; rebindable in Settings.
    static let quickTranscribe = Self("quickTranscribe",
                                      default: .init(.t, modifiers: [.control, .option, .command]))

    /// Live mic dictation: press to start recording, press again to stop + transcribe. Defaults to
    /// ⌃⌥⌘D; rebindable in Settings. Opt-in, disabled by default (Microphone permission, no Accessibility).
    static let dictate = Self("dictate",
                              default: .init(.d, modifiers: [.control, .option, .command]))
}
