import Foundation

/// Languages for manual selection. Whisper is multilingual (~99 languages); «Auto» (empty code)
/// detects the language itself — English and any other work without an extra download.
let whisperLanguages: [(code: String, name: String)] = [
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
