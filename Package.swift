// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Parla",
    // The macOS 14 floor is WhisperKit's (on-device CoreML). The design deliberately does NOT raise it:
    // only APIs available since 14 (materials, gradients), no Liquid Glass.
    // iOS 17: ParlaCore compiles for iOS as-is. WhisperKit and NaturalLanguage are iOS-compatible; the MLX
    // backends are gated to macOS (see the ParlaCore dependencies below + `#if os(macOS)` in the sources).
    platforms: [.macOS(.v14), .iOS(.v17)],
    // ParlaCore is the reusable cross-platform library both apps link. Declaring it as a PRODUCT is what
    // gives xcodebuild a scheme to compile-check it for iOS; the macOS targets and tests depend on the
    // target by name, so they are unaffected by that.
    products: [
        .library(name: "ParlaCore", targets: ["ParlaCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        // Global hotkey via Carbon (RegisterEventHotKey): needs NO Accessibility permission, is rebindable,
        // and ships a ready-made SwiftUI recorder. MIT. Replaces a hand-rolled NSEvent monitor.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        // On-device generative insights for Russian/Ukrainian (Backend B). Apache/MIT. Pulls in mlx-swift,
        // which ships Metal shaders — the reason the .app is assembled with xcodebuild (see build_app.sh).
        // Pinned to an exact tag because the 3.x API churns.
        // We deliberately do NOT use the convenient `#huggingFaceLoadModelContainer` macro: it requires
        // swift-transformers >= 1.3 plus swift-huggingface, which CONFLICTS with WhisperKit's 1.1.x pin.
        // Instead we implement MLXLMCommon's Downloader/TokenizerLoader over the swift-transformers WhisperKit
        // already brings, and call the non-macro `loadModelContainer` (see MLXLLMService).
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.3"),
        // mlx-swift is transitive (via mlx-swift-lm); declared directly so we can `import MLX` for
        // MLX.GPU.set(cacheLimit:). Same constraint mlx-swift-lm uses → the solver unifies to one 0.31.x version.
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.3")),
        // Already in the graph transitively via WhisperKit (Hub/Tokenizers). Declared directly so MLXLLMService
        // can import them; the range matches WhisperKit's own pin (1.1.6..<1.2.0), so there is no conflict.
        .package(url: "https://github.com/huggingface/swift-transformers.git", "1.1.6" ..< "1.2.0"),
        // In-process Ogg/Opus decode. BSD, SPM .binaryTarget. Linked into ParlaCore for iOS AND macOS
        // (Phase 2c: macOS goes native-first, dropping the ffmpeg subprocess from the main decode path — both
        // xcframeworks ship a macos-arm64_x86_64 slice). opus's opusfile.h #includes <ogg/ogg.h> (separate ogg xcframework).
        .package(url: "https://github.com/sbooth/opus-binary-xcframework", from: "0.3.0"),
        .package(url: "https://github.com/sbooth/ogg-binary-xcframework", from: "0.1.3"),
    ],
    targets: [
        // The cross-platform CORE library — the platform-agnostic engine room. Everything the two apps share
        // lives here: the actor-isolated Whisper engine, the audio-decode seams, the on-device AI layer and the
        // whole view-model, so each app is a thin native shell over it.
        .target(
            name: "ParlaCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                // MLX is macOS-only: the generative/embedding backend is gated OUT of the iOS build.
                // The reason is MEMORY, not binary size — measuring settled that. The code costs roughly 15 MB,
                // trivial against the 80 MB __TEXT cap; what does not fit is the model. MLX charges a model's
                // entire weights to `phys_footprint`, which is the figure iOS jetsam kills on (CoreML/ANE weights
                // are largely NOT charged, which is why WhisperKit is fine on iPhone and this is not). Today's 4B
                // model is ~2.3 GB of weights against a per-app budget under ~2 GB on the oldest supported
                // iPhones. A smaller model is the way in, not a bigger binary allowance.
                // `.when(platforms:)` stops SwiftPM linking the Metal packages for iOS; the sources are
                // `#if os(macOS)` with inert iOS stubs (MLXStubs.swift), so the extractive AI path stays live.
                .product(name: "MLXLLM", package: "mlx-swift-lm", condition: .when(platforms: [.macOS])),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(platforms: [.macOS])),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm", condition: .when(platforms: [.macOS])),
                .product(name: "MLX", package: "mlx-swift", condition: .when(platforms: [.macOS])),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
                // The in-process Opus decoder (OpusAudioDecoder.swift) — now on macOS too (Phase 2c native-first:
                // the Mac-App-Store build drops the ffmpeg subprocess). opus needs ogg (opusfile.h → <ogg/ogg.h>).
                .product(name: "opus", package: "opus-binary-xcframework", condition: .when(platforms: [.iOS, .macOS])),
                .product(name: "ogg", package: "ogg-binary-xcframework", condition: .when(platforms: [.iOS, .macOS])),
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
                // MLX generative backend, macOS-only (`.when(platforms:)` mirrors ParlaCore).
                // MLXLLM registers the Qwen3 architecture; MLXLMCommon has loadModelContainer/ChatSession + the
                // Downloader/TokenizerLoader protocols we implement.
                .product(name: "MLXLLM", package: "mlx-swift-lm", condition: .when(platforms: [.macOS])),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(platforms: [.macOS])),
                // On-device sentence-embedding retrieval (Qwen3-Embedding) for query->note semantic search.
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
        // RU/UK streaming-vs-offline WER harness: the dev tool that decided whether streamed dictation text
        // should be authoritative. Kept in the repo because the measurement is part of the argument.
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
            // `Fixtures/tone.ogg` — a 6.7 KB SYNTHETIC Ogg/Opus tone (no voice, safe in a public repo) that lets the
            // real libopusfile decode path run on EVERY machine and in CI, instead of the old opt-in
            // `PARLA_OGG_FIXTURE` env var that meant the native decoder was proven NOWHERE automatically.
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
