import XCTest
import os
import AVFoundation
import AppKit
@testable import ParlaCore
@testable import Parla

/// Shared base for the pure-logic suites split out of the old 5,600-line ParlaLogicTests.
///
/// Carries the process-wide store isolation and the helpers used across more than one suite. The
/// isolation is what keeps a test run from ever touching the user's real data, so it belongs in one
/// place rather than being re-typed per file — this project has already had a test clobber real
/// history, and adding `ChunkProgressStore` to two hand-kept copies of the same block is how that
/// happens again.
class ParlaLogicTestCase: XCTestCase {

    // MARK: Localization (test seam)

    /// Repo root, derived from this file's path (Tests/ParlaTests/… → ../../..).
    var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Point `Localized` at a real `.lproj` from the repo (deterministic, no Bundle.main).
    func activateLocalization(_ lang: String) {
        let lproj = repoRoot.appendingPathComponent("Localization/\(lang).lproj")
        Localized.bundle = Bundle(path: lproj.path) ?? .main
        Localized.currentCode = lang
    }

    /// By default all tests run in Russian (historical expectations = Russian source text).
    override func setUp() {
        super.setUp()
        activateLocalization("ru")
        // Point legacy migration at a non-existent dir so tests never copy the real ~/…/Murmur dataset.
        HistoryStore.legacyBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParlaTests-NoLegacy-\(UUID().uuidString)")
        // CRITICAL ISOLATION: redirect the store itself to a throwaway dir for EVERY test, process-wide. This is
        // the bulletproof guard (not the per-test drain): even a detached refresh Task that outlives a per-test
        // `withTemporaryHistoryStore` scope writes here, never the user's real ~/Library/.../Parla data. Embedding/
        // audio dirs derive from this path, so they're redirected too.
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParlaTests-Store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        // The iOS import container is DELETED FROM by pruneImportedOrphans, so it needs the same treatment as the
        // stores — the prune tests below used to build their fixtures inside the user's REAL container.
        AppModel.importsRoot = storeDir.appendingPathComponent("imports", isDirectory: true)
        HistoryStore.fileURL = storeDir.appendingPathComponent("history.json")
        // ProcessedStore is a SEPARATE global path (not derived from HistoryStore.fileURL) — redirect it too,
        // or folder-watch tests would write the user's real processed.json. (EmbeddingStore/AudioStore DO derive
        // from HistoryStore.fileURL's dir, so they're already covered.)
        ProcessedStore.fileURL = storeDir.appendingPathComponent("processed.json")
        // The MLX model cache is ANOTHER global path that reads the real disk — redirect it to a temp dir so
        // `MLXModelSpec.isDownloaded()` is deterministic (false) in tests. Otherwise, once the user has actually
        // downloaded the RU/UK model, availability tests would see `.ready` and flake. (Same class as above.)
        MLXModelSpec.downloadBase = storeDir.appendingPathComponent("mlx")
        // The embedding-model cache is likewise a separate global path — redirect it so `EmbeddingModelSpec.isDownloaded()`
        // is deterministic (false) in tests; otherwise the retrieval-embedder routing would pick the real downloaded
        // model over the injected fake (the probe already downloaded it on the dev machine).
        EmbeddingModelSpec.downloadBase = storeDir.appendingPathComponent("embed")
        // The long-audio resume record — written after every chunk and deleted at the end. Same class again:
        // without a redirect a test run would clobber a real half-finished job the user left mid-transcription.
        ChunkProgressStore.fileURL = storeDir.appendingPathComponent("chunk-progress.json")
    }


    /// True when the host's NLTagger has the Russian lemma asset (inflected → dictionary-form reduction).
    /// Fresh CI runners lack it — the on-device NL language models download on demand and aren't present on a
    /// clean image — so the morphology tests `XCTSkipUnless` this: meaningful on a dev machine (asset present),
    /// green in CI (asset absent). The feature itself degrades gracefully at runtime when the asset is missing.
    var hasRussianLemmatizer: Bool { searchLemmaSet(of: "работе").contains("работа") }

    // MARK: helpers

    func stat(_ name: String, _ size: Int64, _ mtime: TimeInterval) -> WatchedFileStat {
        WatchedFileStat(url: URL(fileURLWithPath: "/watch/\(name)"), size: size,
                        mtime: Date(timeIntervalSince1970: mtime))
    }

    func makeItem(name: String = "a.ogg", text: String, segments: [Segment] = [],
                          lang: String = "ru", model: String = "openai_whisper-tiny",
                          edited: Bool? = nil) -> TranscriptItem {
        var item = TranscriptItem(sourceName: name, language: lang, durationSec: 1, model: model,
                                  text: text, segments: segments)
        item.edited = edited
        return item
    }

    /// Run a block with a temporary history file — so that saveEdit/HistoryStore.save do NOT touch
    /// the user's real history in ~/Library/Application Support/Parla/.
    func withTemporaryHistoryStore(_ body: () -> Void) {
        let original = HistoryStore.fileURL
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ParlaTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        HistoryStore.fileURL = dir.appendingPathComponent("history.json")
        defer {
            // Restores to the setUp baseline (itself a temp dir), so a detached Task that outlives this scope
            // can only ever touch temp data — the real store is unreachable for the whole test process. (No drain
            // needed: process-wide isolation in setUp is the real guard, not a timing race against a kicked Task.)
            HistoryStore.fileURL = original
            try? FileManager.default.removeItem(at: dir)
        }
        body()
    }

    /// Async sibling of withTemporaryHistoryStore — for `await transcribe(...)` orchestration tests.
    /// `@MainActor` so the @MainActor orchestration tests don't "send" the (non-Sendable) XCTestCase
    /// across isolation when they `await` it under Swift 6.
    @MainActor
    func withTemporaryHistoryStoreAsync(_ body: @MainActor () async -> Void) async {
        let original = HistoryStore.fileURL
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ParlaTest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        HistoryStore.fileURL = dir.appendingPathComponent("history.json")
        defer {
            // See sync variant: restores to the setUp temp baseline, so a detached refresh Task that outlives this
            // scope still can't reach the real store. Process-wide isolation in setUp is the guard, not a drain.
            HistoryStore.fileURL = original
            try? FileManager.default.removeItem(at: dir)
        }
        await body()
    }

    /// A real, directly-playable (.m4a) temp source so keepAudio's copy succeeds without ffmpeg.
    func makeTempSource(_ name: String = "v.m4a") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        try? Data("audio".utf8).write(to: url)
        return url
    }
}
