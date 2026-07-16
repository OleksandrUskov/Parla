import Foundation

/// Languages for manual selection. Whisper is multilingual (~99 languages); «Auto» (empty code)
/// detects the language itself — English and any other work without an extra download.
public let whisperLanguages: [(code: String, name: String)] = [
    ("",   ""),   // «Auto» — localized at render time (key lang.auto); the other names are endonyms
    ("ru", "Русский"),
    ("uk", "Українська"),
    ("en", "English"),
    ("de", "Deutsch"),
    ("fr", "Français"),
    ("es", "Español"),
    ("it", "Italiano"),
    ("pt", "Português"),
    ("pl", "Polski"),
    ("nl", "Nederlands"),
    ("tr", "Türkçe"),
    ("cs", "Čeština"),
    ("sv", "Svenska"),
    ("ro", "Română"),
    ("el", "Ελληνικά"),
    ("hu", "Magyar"),
    ("ar", "العربية"),
    ("he", "עברית"),
    ("hi", "हिन्दी"),
    ("ja", "日本語"),
    ("ko", "한국어"),
    ("zh", "中文"),
    ("id", "Bahasa Indonesia"),
    ("vi", "Tiếng Việt"),
    ("th", "ไทย"),
    ("ka", "ქართული"),
    ("kk", "Қазақша"),
    ("be", "Беларуская"),
    ("az", "Azərbaycanca"),
    ("hy", "Հայերէն"),
]

// MARK: - Pure text/language helpers (shared across the Core + app)

/// Russian pluralization (1 файл / 2 файла / 5 файлов).
public func pluralRu(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let a = abs(n) % 100, b = a % 10
    if a > 10 && a < 20 { return many }
    if b == 1 { return one }
    if b >= 2 && b <= 4 { return few }
    return many
}

/// Primary BCP-47 subtag, lowercased: `"en-US"`/`"EN_us"` → `"en"`, `""` → `""`. Pure + testable —
/// used to match a transcript's language code against a backend's supported-language set.
public func languagePrimarySubtag(_ code: String) -> String {
    code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
}
