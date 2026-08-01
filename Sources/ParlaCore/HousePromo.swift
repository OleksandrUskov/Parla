import SwiftUI

/// D2 "house" cross-promo (Branch 2): a tasteful, in-binary card for the developer's OTHER apps. ZERO network —
/// it just opens the App Store via `openURL`, so it keeps the "Data Not Collected" privacy label intact (no ad
/// SDK, no tracking, no phone-home). Non-intrusive: it lives at the bottom of Settings (About area).
public struct HouseApp: Identifiable, Sendable {
    public let id: String        // App Store id (e.g. "id123456789")
    public let name: String
    public let tagline: String
    public let url: URL
    public init(id: String, name: String, tagline: String, url: URL) {
        self.id = id; self.name = name; self.tagline = tagline; self.url = url
    }
}

public enum HouseApps {
    /// The developer's other apps to cross-promote. EMPTY by default → the card ships HIDDEN until the owner adds
    /// real entries (so nothing fake/placeholder ever renders). To enable, add e.g.:
    ///   HouseApp(id: "id0000000000", name: "Cursaris",
    ///            tagline: "…", url: URL(string: "https://apps.apple.com/app/id0000000000")!)
    public static let entries: [HouseApp] = []
}

/// A drop-in Settings section listing `HouseApps.entries` (renders nothing when empty). Both apps place it in the
/// About area, above the tip-jar. Tapping a row opens the App Store — no network call from Parla itself.
public struct HousePromoCard: View {
    @Environment(\.openURL) private var openURL
    public init() {}

    public var body: some View {
        if !HouseApps.entries.isEmpty {
            Section(L("house.section")) {
                ForEach(HouseApps.entries) { app in
                    Button { openURL(app.url) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.headline)
                            Text(app.tagline).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}
