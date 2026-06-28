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
        .executableTarget(
            name: "Parla",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                // MLX generative backend (AI P3). MLXLLM registers the Qwen3 architecture; MLXLMCommon
                // has loadModelContainer/ChatSession + the Downloader/TokenizerLoader protocols we implement.
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                // P3.5: on-device sentence-embedding retrieval (Qwen3-Embedding) for query→note semantic search.
                // Same pinned package, NO new dependency, no swift-transformers conflict (MLXEmbedders deps = MLX/MLXNN/MLXLMCommon only).
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),   // MLX.GPU.set(cacheLimit:) — bound the Metal buffer cache

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
            dependencies: ["Parla"],
            path: "Tests/ParlaTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
