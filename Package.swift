// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Parla",
    // Пол = macOS 14: его требует WhisperKit (on-device CoreML). Дизайн НЕ поднимает
    // эту планку — только API, доступные с 14 (материалы, градиенты), без Liquid Glass.
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // Глобальный хоткей через Carbon (RegisterEventHotKey) — БЕЗ «Универсального доступа»,
        // переназначаемый, с готовым SwiftUI-рекордером. MIT. Замена ручному NSEvent-монитору.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Parla",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/Parla",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ParlaSmoke",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/ParlaSmoke",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ParlaTests",
            dependencies: ["Parla"],
            path: "Tests/ParlaTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
