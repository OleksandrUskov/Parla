import XCTest
import os
import AVFoundation
import AppKit
@testable import ParlaCore
@testable import Parla

/// Model names, tiers, paths and pinned revisions; languages; file collection; formatting; and the build-shape guards (privacy manifest, inert defaults).
final class ModelConfigTests: ParlaLogicTestCase {
    // MARK: Model names

    func testPrettyModel() {
        XCTAssertEqual(prettyModel("openai_whisper-tiny"), "Tiny")
        XCTAssertEqual(prettyModel("openai_whisper-large-v3"), "Large v3")
        XCTAssertEqual(prettyModel(""), "")
    }

    func testFriendlyModel() {
        XCTAssertEqual(friendlyModel("openai_whisper-large-v3-v20240930_626MB"), "Large v3 turbo")
        XCTAssertEqual(friendlyModel("openai_whisper-large-v3-v20240930"), "Large v3 turbo")
        XCTAssertEqual(friendlyModel("openai_whisper-large-v3"), "Large v3")
        XCTAssertEqual(friendlyModel("openai_whisper-large-v3_947MB"), "Large v3")
        XCTAssertEqual(friendlyModel("distil-whisper_distil-large-v3"), "Distil Large v3")
        XCTAssertEqual(friendlyModel("openai_whisper-large-v2_949MB"), "Large v2")
        XCTAssertEqual(friendlyModel("openai_whisper-medium"), "Medium")
        XCTAssertEqual(friendlyModel("openai_whisper-small"), "Small")
        XCTAssertEqual(friendlyModel("openai_whisper-base"), "Base")
        XCTAssertEqual(friendlyModel("openai_whisper-tiny"), "Tiny")
        XCTAssertEqual(friendlyModel("something-weird"), prettyModel("something-weird"))
    }


    // MARK: Formatting

    func testFmtTime() {
        XCTAssertEqual(fmtTime(0), "00:00")
        XCTAssertEqual(fmtTime(5), "00:05")
        XCTAssertEqual(fmtTime(59), "00:59")
        XCTAssertEqual(fmtTime(60), "01:00")
        XCTAssertEqual(fmtTime(65), "01:05")
        XCTAssertEqual(fmtTime(3661), "61:01")
    }

    func testFormatBytes() {
        XCTAssertEqual(formatBytes(0), "—")
        XCTAssertEqual(formatBytes(-5), "—")
        XCTAssertEqual(formatBytes(500 * 1_048_576), "500 МБ")
        XCTAssertEqual(formatBytes(Int64(1.5 * 1024 * 1_048_576)), "1.5 ГБ")
    }


    // MARK: Default model selection

    func testBestDefault() {
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-base", "openai_whisper-large-v3-v20240930"]),
                       "openai_whisper-large-v3-v20240930")
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-base", "openai_whisper-large-v3-v20240930_626MB"]),
                       "openai_whisper-large-v3-v20240930_626MB")
        // 626MB quantized turbo wins over the full-precision 1.5GB variant when BOTH are present
        // (measured: quantized decodes RU better + is smaller).
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-large-v3-v20240930", "openai_whisper-large-v3-v20240930_626MB"]),
                       "openai_whisper-large-v3-v20240930_626MB")
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-large-v3", "openai_whisper-tiny"]),
                       "openai_whisper-large-v3")
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-small", "openai_whisper-base"]),
                       "openai_whisper-base")
        XCTAssertEqual(AppModel.bestDefault(from: ["openai_whisper-small"]), "openai_whisper-small")
        XCTAssertEqual(AppModel.bestDefault(from: []), "openai_whisper-base")
    }

    func testRepinnedLanguage() {
        // Unchanged explicit pick → keep the current lock (which auto-detect may have pinned).
        XCTAssertEqual(AppModel.repinnedLanguage(explicit: "ru", lastExplicit: "ru", locked: "ru").locked, "ru")
        XCTAssertEqual(AppModel.repinnedLanguage(explicit: nil, lastExplicit: nil, locked: "uk").locked, "uk")
        // User switches the pill mid-dictation RU→EN → re-pin the lock to the new explicit choice.
        let toEN = AppModel.repinnedLanguage(explicit: "en", lastExplicit: "ru", locked: "ru")
        XCTAssertEqual(toEN.locked, "en"); XCTAssertEqual(toEN.lastExplicit, "en")
        // User switches to Auto (explicit nil) → drop the lock to nil so detection re-pins next window.
        let toAuto = AppModel.repinnedLanguage(explicit: nil, lastExplicit: "ru", locked: "ru")
        XCTAssertNil(toAuto.locked); XCTAssertNil(toAuto.lastExplicit)
    }


    // MARK: Model paths / sizes

    func testLocalFolderPath() {
        let url = TranscriptionEngine.localFolder("openai_whisper-tiny")
        XCTAssertTrue(url.path.hasSuffix("huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-tiny"),
                      url.path)
    }

    func testFolderSize() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1000).write(to: tmp.appendingPathComponent("a.bin"))
        try Data(repeating: 0, count: 2000).write(to: tmp.appendingPathComponent("sub/b.bin"))
        XCTAssertEqual(TranscriptionEngine.folderSize(at: tmp), 3000)
        XCTAssertEqual(TranscriptionEngine.folderSize(at: tmp.appendingPathComponent("nope")), 0)
    }


    // MARK: Collecting audio files from a folder

    func testAudioFiles() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for name in ["b.mp3", "a.ogg", "note.txt", "image.png"] {
            try Data("x".utf8).write(to: tmp.appendingPathComponent(name))
        }
        try Data("x".utf8).write(to: tmp.appendingPathComponent("sub/d.wav"))

        let found = AppModel.audioFiles(in: tmp).map { $0.lastPathComponent }
        XCTAssertEqual(found, ["a.ogg", "b.mp3", "d.wav"])  // audio only, sorted by name
        XCTAssertFalse(found.contains("note.txt"))
        XCTAssertFalse(found.contains("image.png"))
    }


    // MARK: Languages

    func testLanguages() {
        XCTAssertGreaterThan(whisperLanguages.count, 20)
        XCTAssertEqual(whisperLanguages.first?.code, "")   // «Auto» first
        XCTAssertTrue(whisperLanguages.contains { $0.code == "en" })
        XCTAssertTrue(whisperLanguages.contains { $0.code == "ru" })
        XCTAssertTrue(whisperLanguages.contains { $0.code == "uk" })
        // codes are unique
        XCTAssertEqual(Set(whisperLanguages.map(\.code)).count, whisperLanguages.count)
    }


    // MARK: Model tiers

    @MainActor func testModelTiersCuration() {
        let m = AppModel()
        m.availableModels = [
            "openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small",
            "openai_whisper-large-v3-v20240930_626MB", "openai_whisper-large-v3",
            "openai_whisper-large-v3_947MB", "distil-whisper_distil-large-v3",
        ]
        m.selectedModel = "openai_whisper-large-v3-v20240930_626MB"
        let tiers = m.modelTiers

        XCTAssertEqual(tiers.count, 5)                                   // 5 tiers, no clones
        XCTAssertEqual(tiers.first(where: { $0.recommended })?.name,
                       "openai_whisper-large-v3-v20240930_626MB")
        XCTAssertTrue(tiers.contains { $0.title == "Large v3 turbo" })
        XCTAssertFalse(tiers.contains { $0.name.contains("distil") })
        XCTAssertFalse(tiers.contains { $0.name.contains("947MB") })
    }

    @MainActor func testModelTiersCurrentFallback() {
        let m = AppModel()
        m.availableModels = [
            "openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small",
            "openai_whisper-large-v3-v20240930_626MB", "openai_whisper-large-v3",
            "openai_whisper-large-v2_949MB",
        ]
        m.selectedModel = "openai_whisper-large-v2_949MB"   // matches no tier
        let tiers = m.modelTiers
        XCTAssertEqual(tiers.count, 6)                       // 5 + «current»
        XCTAssertEqual(tiers.last?.name, "openai_whisper-large-v2_949MB")
        XCTAssertEqual(tiers.last?.title, "Large v2")
    }


    // MARK: Privacy manifest — it must match the code that actually ships in the iOS bundle

    /// The manifest is a CLAIM about the binary, and Apple rejects the upload (ITMS-91053) when the claim is
    /// short. It said "no FileTimestamp" while ShareInbox already read .contentModificationDateKey, and the
    /// comment asserting the absence was wrong when it was written. Prose cannot be trusted to stay true, so
    /// this derives the answer from the sources the iOS target actually compiles.
    ///
    /// Scope note: the iOS app target is apps/ios/Sources + apps/ios/Shared + ParlaCore. Sources/Parla is the
    /// macOS app and is NOT in this bundle, so its own timestamp use does not belong here.
    func testPrivacyManifestDeclaresEveryRequiredReasonAPIThatShipsInTheIOSBundle() throws {
        let manifest = try String(contentsOf: repoRoot.appendingPathComponent("apps/ios/PrivacyInfo.xcprivacy"),
                                  encoding: .utf8)
        let fm = FileManager.default
        var code = ""
        for dir in ["apps/ios/Sources", "apps/ios/Shared", "Sources/ParlaCore"] {
            let root = repoRoot.appendingPathComponent(dir)
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "swift" {
                code += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
        XCTAssertFalse(code.isEmpty, "precondition: the iOS bundle's sources were found")

        // (marker in code, Apple's manifest category)
        let required: [(String, String)] = [
            ("contentModificationDateKey", "NSPrivacyAccessedAPICategoryFileTimestamp"),
            ("creationDateKey", "NSPrivacyAccessedAPICategoryFileTimestamp"),
            ("volumeAvailableCapacity", "NSPrivacyAccessedAPICategoryDiskSpace"),
            ("systemUptime", "NSPrivacyAccessedAPICategorySystemBootTime"),
            ("activeInputModes", "NSPrivacyAccessedAPICategoryActiveKeyboards"),
        ]
        for (marker, category) in required where code.contains(marker) {
            XCTAssertTrue(manifest.contains(category),
                          "\(marker) ships in the iOS bundle but the manifest does not declare \(category)")
        }
        // UserDefaults is used unconditionally and must always be declared.
        XCTAssertTrue(manifest.contains("NSPrivacyAccessedAPICategoryUserDefaults"))
        // And the promises the product is built on.
        XCTAssertTrue(manifest.contains("<key>NSPrivacyTracking</key>\n    <false/>"), "no tracking, ever")
    }


    // MARK: No shipping code may ask whether it is running under test

    /// The shipped binary carried `NSClassFromString("XCTestCase")` in five places. Two of them decided which
    /// SERVICES production used, so the real path was chosen by a runtime guess about the process rather than by
    /// the app; the other three were belt-and-braces over seams that already default to inert. All are gone —
    /// production behaviour is wired by `AppModel.mac()` / `AppModel.iOS()`, and safety comes from the default.
    /// Comments may still MENTION the old pattern (they explain why it went); code may not use it.
    func testNoShippingCodeDetectsXCTest() throws {
        let fm = FileManager.default
        var offenders: [String] = []
        for dir in ["Sources", "apps/ios/Sources", "apps/ios/Shared", "apps/ios/Extensions"] {
            let root = repoRoot.appendingPathComponent(dir)
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for (i, line) in text.components(separatedBy: .newlines).enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    guard !code.hasPrefix("//") else { continue }      // a comment explaining the history is fine
                    if code.contains("XCTestCase") {
                        offenders.append("\(url.lastPathComponent):\(i + 1)  \(code)")
                    }
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty,
                      "shipping code must not branch on being under test — wire the behaviour in the app factory "
                      + "and let the Core default stay inert:\n" + offenders.joined(separator: "\n"))
    }


    // MARK: The Core's defaults must be INERT — production is wired by the app, not guessed at runtime

    /// This used to be enforced by production code asking `NSClassFromString("XCTestCase")` whether it was under
    /// test — test-detection shipped inside the app binary, and the production path chosen by a runtime guess
    /// rather than by the app. The default is now inert and the platform factories wire the real services, which
    /// is this codebase's own stated pattern everywhere else. This test is what stops the guess coming back: if
    /// someone makes the Core default to a real service, a forgotten injection silently loads an ML model in the
    /// middle of the suite — which is exactly how this project once got a process-killing MLX abort.
    @MainActor func testCoreDefaultsAreInertServices() {
        let m = AppModel(engine: FakeEngine())
        XCTAssertTrue(m.ai is NoopAIService,
                      "the Core must default to an inert AI service; the app wires the real one")
        XCTAssertTrue(m.embedder is NoopEmbedder,
                      "the Core must default to an inert embedder; the app wires the real one")
    }

    /// …and the production services must still be reachable by name, or the factories have nothing to wire.
    @MainActor func testProductionServicesAreAvailableToTheAppFactories() {
        XCTAssertFalse(AppModel.productionAI() is NoopAIService)
        XCTAssertFalse(AppModel.productionEmbedder() is NoopEmbedder)
    }


    // MARK: Model revisions must be PINNED — a branch is not a dependency

    /// `main` meant a new user downloaded whatever the community repo had been re-pushed to that day, i.e.
    /// silently different weights from the ones this project measured its quality on — and no bug report could
    /// ever surface it. This guards against a well-meaning "simplify" putting a branch name back.
    func testCommunityModelRevisionsArePinnedToCommits() {
        let pinned = [("MLXModelSpec", MLXModelSpec.revision),
                      ("EmbeddingModelSpec.active", EmbeddingModelSpec.active.revision),
                      ("EmbeddingModelSpec.bgeM3Fallback", EmbeddingModelSpec.bgeM3Fallback.revision)]
        for (name, rev) in pinned {
            XCTAssertEqual(rev.count, 40, "\(name): a commit SHA is 40 chars — '\(rev)' looks like a branch")
            XCTAssertTrue(rev.allSatisfy { $0.isHexDigit }, "\(name): '\(rev)' is not a hex commit SHA")
            XCTAssertNotEqual(rev, "main", "\(name) must never track a moving branch")
        }
    }


}
