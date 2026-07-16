import ActivityKit
import Foundation

/// Live Activity attributes for an in-progress transcription. Compiled into BOTH the app and the
/// `ParlaWidgets` extension via target membership — NOT through ParlaCore, which the extension must not link (its
/// ~30 MB memory budget). Foundation + ActivityKit only. The APP owns localization: it puts an already-localized
/// `label` into the state, so the widget (which can't reach `L()`) simply renders the string.
struct ParlaTranscriptionAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var label: String     // already-localized status line ("Расшифровка…" / "Transcribing…" / "Загрузка модели…")
        var title: String     // the file / note name being processed
        var done: Int         // chunks completed (a long-audio / multi-file batch)
        var total: Int        // chunks total (≤1 → indeterminate; no bar)

        /// 0…1 for a multi-chunk batch, nil (no determinate bar) otherwise.
        var fraction: Double? { total > 1 ? min(1, max(0, Double(done) / Double(total))) : nil }
    }
}
