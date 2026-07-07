// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Parla",
    // Пол = macOS 14: его требует WhisperKit (on-device CoreML). Дизайн НЕ поднимает
    // эту планку — только API, доступные с 14 (материалы, градиенты), без Liquid Glass.
    // iOS 17 (iOS-port P1.0): ParlaCore компилится под iOS (acid-test P0). WhisperKit/NaturalLanguage
    // iOS-совместимы; MLX-бэкенды гейтятся под macOS (см. ParlaCore deps ниже + #if os(macOS) в источниках).
    platforms: [.macOS(.v14), .iOS(.v17)],
    // ParlaCore — переиспользуемая кросс-платформенная библиотека (движок), которую линкует и
    // macOS-app, и (будущий) iOS-app. Объявлена продуктом → появляется xcodebuild-схема для
    // iOS-компайл-чека (iOS-port P1.0). macOS-таргеты/тесты зависят от target'а по имени — не затронуты.
    products: [
        .library(name: "ParlaCore", targets: ["ParlaCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // Глобальный хоткей через Carbon (RegisterEventHotKey) — БЕЗ «Универсального доступа»,
        // переназначаемый, с готовым SwiftUI-рекордером. MIT. Замена ручному NSEvent-монитору.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        // On-device генеративные инсайты для RU/UK (AI P3, Backend B). Apache/MIT. Тянет mlx-swift
        // (Metal — поэтому сборка через xcodebuild, см. build_app.sh). Пин тега (v3.x чурнится API).
        // НЕ юзаем удобный #huggingFaceLoadModelContainer-макрос: он требует swift-transformers ≥1.3 +
        // swift-huggingface, что КОНФЛИКТУЕТ с пином WhisperKit (1.1.x). Вместо него — свои Downloader/
        // TokenizerLoader поверх transformers WhisperKit'а + не-макро loadModelContainer (см. MLXLLMService).
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.3"),
        // mlx-swift is transitive (via mlx-swift-lm); declared directly so we can `import MLX` for
        // MLX.GPU.set(cacheLimit:). Same constraint mlx-swift-lm uses → the solver unifies to one 0.31.x version.
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.3")),
        // Уже в графе транзитивно через WhisperKit (Hub/Tokenizers). Объявляем прямо, чтобы импортировать
        // их в MLXLLMService; диапазон совпадает с пином WhisperKit (1.1.6..<1.2.0) → конфликта нет.
        .package(url: "https://github.com/huggingface/swift-transformers.git", "1.1.6" ..< "1.2.0"),
    ],
    targets: [
        // Cross-platform CORE library (iOS-port P0.2b): the platform-agnostic engine room, extracted so it
        // ports to an iOS target unchanged (IOS_PORT.md §1). This first slice is the pure
        // localization + language + text foundation (Foundation + NaturalLanguage only, no external deps); the
        // heavier logic/models/engines migrate in follow-up steps. The macOS app + tests depend on it.
        .target(
            name: "ParlaCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                // MLX = macOS-only (iOS-port P1): the generative/embedding backend is gated OUT of the iOS build
                // (binary size / RAM; IOS_PORT §4). `.when(platforms:)` stops SwiftPM linking the Metal packages for
                // iOS; the sources are `#if os(macOS)` with inert iOS stubs (MLXStubs.swift), so the extractive AI
                // path stays live. iOS keeps WhisperKit + NaturalLanguage.
                .product(name: "MLXLLM", package: "mlx-swift-lm", condition: .when(platforms: [.macOS])),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(platforms: [.macOS])),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm", condition: .when(platforms: [.macOS])),
                .product(name: "MLX", package: "mlx-swift", condition: .when(platforms: [.macOS])),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
            ],
            path: "Sources/ParlaCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Parla",
            dependencies: [
                "ParlaCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                // MLX generative backend (AI P3), macOS-only (iOS-port P1 — `.when(platforms:)` mirrors ParlaCore).
                // MLXLLM registers the Qwen3 architecture; MLXLMCommon has loadModelContainer/ChatSession + the
                // Downloader/TokenizerLoader protocols we implement.
                .product(name: "MLXLLM", package: "mlx-swift-lm", condition: .when(platforms: [.macOS])),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(platforms: [.macOS])),
                // P3.5: on-device sentence-embedding retrieval (Qwen3-Embedding) for query→note semantic search.
                // Same pinned package, NO new dependency, no swift-transformers conflict (MLXEmbedders deps = MLX/MLXNN/MLXLMCommon only).
                .product(name: "MLXEmbedders", package: "mlx-swift-lm", condition: .when(platforms: [.macOS])),
                .product(name: "MLX", package: "mlx-swift", condition: .when(platforms: [.macOS])),   // MLX.GPU.set(cacheLimit:) — bound the Metal buffer cache

                // swift-transformers (WhisperKit's 1.1.x) backs our Downloader (Hub.HubApi) + TokenizerLoader (AutoTokenizer).
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
            ],
            path: "Sources/Parla",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "ParlaSmoke",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/ParlaSmoke",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // RU/UK streaming-vs-offline WER harness (dev tool, MIC_DICTATION P3 gate).
        .executableTarget(
            name: "ParlaStreamEval",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/ParlaStreamEval",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ParlaTests",
            dependencies: ["ParlaCore", "Parla"],
            path: "Tests/ParlaTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
