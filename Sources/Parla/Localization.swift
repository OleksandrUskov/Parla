import Foundation

/// In-app localization (en / ru / uk) with a runtime language switch independent of the system
/// language. Strings are resolved against the `.lproj` of the user-chosen UI language via an
/// explicit bundle — deterministic regardless of how SwiftUI treats `environment(\.locale)`, and
/// fully unit-testable (point `Localized.bundle` at any `.lproj` and assert the output).
///
/// Call sites use the free helpers `L("key")` / `Lf("key", args…)`; both return a plain `String`,
/// so `Text(L("key"))` hits SwiftUI's verbatim initializer (no accidental double localization).
enum Localized {
    /// The `.lproj` bundle for the chosen UI language (or the base bundle for "system").
    /// `nonisolated(unsafe)`: written only on the main actor (picker / launch), read from anywhere
    /// (e.g. background `LocalizedError.errorDescription`). A read during a switch is harmless —
    /// at worst one string resolves against the previous language for an instant.
    nonisolated(unsafe) static var bundle: Bundle = .main

    /// Base bundle that holds the `<lang>.lproj` folders. `.main` in the app; tests may override it.
    nonisolated(unsafe) static var baseBundle: Bundle = .main

    /// Resolved language code currently in effect ("en" / "ru" / "uk"). Drives plural selection.
    nonisolated(unsafe) static var currentCode: String = "en"

    /// Switch the active UI language. `code == nil` → follow the system (base bundle).
    static func setLanguage(_ code: String?) {
        if let code, let path = baseBundle.path(forResource: code, ofType: "lproj"),
           let lproj = Bundle(path: path) {
            bundle = lproj
            currentCode = code
        } else {
            bundle = baseBundle
            currentCode = code ?? systemBestCode()
        }
    }

    /// Best supported code for the current system language (falls back to English).
    private static func systemBestCode() -> String {
        let sys = Locale.current.language.languageCode?.identifier ?? "en"
        return ["ru", "uk", "en"].contains(sys) ? sys : "en"
    }

    /// Resolve a key against the active language bundle; missing key → the key itself (visible in dev).
    static func string(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Resolve + `String(format:)` for keys carrying `%@` / `%lld` / positional placeholders.
    static func format(_ key: String, _ args: [CVarArg]) -> String {
        String(format: string(key), arguments: args)
    }

    /// Every bundled-language rendering of a key (en/ru/uk + the active bundle). Used to match a STORED localized
    /// string regardless of the CURRENT UI language — the value was saved in whatever language was active back then
    /// (e.g. the "silence" placeholder on a silent clip), so a single-language compare would miss after a switch.
    static func allLanguageStrings(_ key: String) -> Set<String> {
        var out: Set<String> = [string(key)]
        for code in ["en", "ru", "uk"] {
            if let path = baseBundle.path(forResource: code, ofType: "lproj"), let b = Bundle(path: path) {
                out.insert(b.localizedString(forKey: key, value: key, table: nil))
            }
        }
        return out
    }
}

/// Localized string for `key` in the active UI language.
func L(_ key: String) -> String { Localized.string(key) }

/// Localized + formatted string (`%@`, `%lld`, `%1$@`…) in the active UI language.
func Lf(_ key: String, _ args: CVarArg...) -> String { Localized.format(key, args) }

// MARK: - UI language choice

/// User-selectable interface language — only the languages we actually ship. No "System" option:
/// an Italian-system user choosing "System" would silently get the English fallback (misleading).
/// Independent of the speech-recognition `AppModel.language` (that one is the spoken language).
enum UILanguage: String, CaseIterable, Identifiable {
    case en, ru, uk
    var id: String { rawValue }

    /// BCP-47 code matching the `.lproj` folder.
    var code: String { rawValue }

    /// Locale for SwiftUI `environment(\.locale)` (formatting + system controls).
    var locale: Locale { Locale(identifier: rawValue) }

    /// Picker label — each language names itself (endonym).
    var pickerLabel: String {
        switch self {
        case .en: return "English"
        case .ru: return "Русский"
        case .uk: return "Українська"
        }
    }
}

// MARK: - Plurals (CLDR per language)

/// English plural (one / other).
func pluralEn(_ n: Int, _ one: String, _ other: String) -> String { abs(n) == 1 ? one : other }

/// Ukrainian plural — same CLDR categories as Russian (one / few / many).
func pluralUk(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    pluralRu(n, one, few, many)
}

/// Localized "transcription(s)" word agreeing with `n` in the active UI language.
func transcriptionsWord(_ n: Int) -> String {
    switch Localized.currentCode {
    case "en": return pluralEn(n, L("word.transcription.one"), L("word.transcription.many"))
    case "uk": return pluralUk(n, L("word.transcription.one"), L("word.transcription.few"), L("word.transcription.many"))
    default:   return pluralRu(n, L("word.transcription.one"), L("word.transcription.few"), L("word.transcription.many"))
    }
}
