import SwiftUI

public enum Brand {
    public static let name = "Parla"
    public static let c1 = Color(hex: 0x6D5DF6)   // indigo
    public static let c2 = Color(hex: 0x8B5CF6)   // violet
    public static let c3 = Color(hex: 0xB14AED)   // purple
    public static let accent = c2
    public static let gradient = LinearGradient(colors: [c1, c3], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Color {
    public init(hex: UInt) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

/// Dark «aurora» background built from soft radial blobs. macOS 14 APIs only
/// (RadialGradient + blur) — no MeshGradient/Liquid Glass, works everywhere.
public struct AuroraBackground: View {
    public init() {}
    public var body: some View {
        ZStack {
            Color(hex: 0x141220)
            ZStack {
                blob(0x6D5DF6, x: 0.20, y: 0.20, size: 540, opacity: 0.55)
                blob(0xB14AED, x: 0.84, y: 0.16, size: 480, opacity: 0.45)
                blob(0x4338CA, x: 0.74, y: 0.86, size: 580, opacity: 0.50)
                blob(0x7C3AED, x: 0.24, y: 0.84, size: 460, opacity: 0.42)
            }
            .blur(radius: 70)
            LinearGradient(colors: [.clear, .black.opacity(0.30)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private func blob(_ hex: UInt, x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double) -> some View {
        GeometryReader { geo in
            Circle()
                .fill(RadialGradient(colors: [Color(hex: hex).opacity(opacity), .clear],
                                     center: .center, startRadius: 0, endRadius: size / 2))
                .frame(width: size, height: size)
                .position(x: geo.size.width * x, y: geo.size.height * y)
        }
    }
}
