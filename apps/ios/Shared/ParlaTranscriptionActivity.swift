import ActivityKit
import Foundation

/// Live Activity attributes for an in-progress transcription. Compiled into BOTH the app and the
/// `ParlaWidgets` extension via target membership — NOT through ParlaCore, which the extension must not link (its
/// ~30 MB memory budget). Foundation + ActivityKit only. The APP owns localization: it puts an already-localized
/// `label` into the state, so the widget (which can't reach `L()`) simply renders the string.
struct ParlaTranscriptionAttributes: ActivityAttributes, Sendable {
    // `Sendable` is NOT inherited from `ActivityAttributes` — the SDK protocol requires only Decodable/Encodable
    // (checked in the .swiftinterface). Both types are immutable value types of Strings and Ints, so declaring it
    // is free and correct, and it is what makes `ActivityContent` Sendable (the SDK conforms it conditionally on
    // `State: Sendable`). Without it, handing state to ActivityKit reads as a cross-isolation send.
    public struct ContentState: Codable, Hashable, Sendable {
        var label: String     // already-localized status line ("Расшифровка…" / "Transcribing…" / "Загрузка модели…")
        var title: String     // the file / note name being processed
        var done: Int         // chunks completed (a long-audio / multi-file batch)
        var total: Int        // chunks total (≤1 → indeterminate; no bar)

        /// 0…1 for a multi-chunk batch, nil (no determinate bar) otherwise.
        var fraction: Double? { total > 1 ? min(1, max(0, Double(done) / Double(total))) : nil }
    }
}
