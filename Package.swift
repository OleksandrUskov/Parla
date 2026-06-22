// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "Murmur",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/Murmur",
            swiftSettings: [
                // v1: ленивый Swift 5 режим — без боя со строгой concurrency Swift 6.
                .swiftLanguageMode(.v5),
            ]
        ),
        // Технический таргет: headless-прогон WhisperKit для проверки движка.
        .executableTarget(
            name: "MurmurSmoke",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/MurmurSmoke",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
