import SwiftUI

/// Brand palette for the ParlaWidgets extension — it can't link ParlaCore/BrandTheme, so we mirror `Brand`
/// (indigo→purple) with a local `Color(hex:)`. Widget-target-only (this folder is not in the app target), so
/// there's no clash with ParlaCore's own `Color(hex:)`.
enum WidgetBrand {
    static let c1 = Color(hex: 0x6D5DF6)   // indigo
    static let c3 = Color(hex: 0xB14AED)   // purple
    static let accent = Color(hex: 0x8B5CF6)   // violet (== Brand.accent)
    static let gradient = LinearGradient(colors: [c1, c3], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Color {
    init(hex: UInt) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
