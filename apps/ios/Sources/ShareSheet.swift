import SwiftUI
import UIKit

/// A rendered export file to share — Identifiable so it can drive `.sheet(item:)`.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Bridges UIKit's `UIActivityViewController` (the system share sheet — Save to Files, AirDrop, Messages,
/// Copy, …) into SwiftUI. iOS export renders a transcript / the whole history to a temp file via the
/// pure Core formatters (`exportString` / `exportJSON` / `exportText`), then shares the file URL so the user
/// gets the right filename + every share/save destination for free. Presenting it as a `.sheet`'s content
/// hosts the activity controller inside the sheet, which avoids the iPad "popover needs a source" crash.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
