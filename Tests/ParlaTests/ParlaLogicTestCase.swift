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
class ParlaLogicTestCase: ParlaTestCase {

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

    /// The store isolation itself lives in `ParlaTestCase` — this only adds the language.
    ///
    /// It used to be a second, hand-kept copy of that whole block, which is exactly the failure mode the base
    /// class was written to prevent (its own doc says the redirects live there "once, and pipeline tests inherit
    /// them rather than remembering to copy a setUp"). The copy drifted into being anyway, and the cost showed
    /// up the day `ChunkProgressStore` — a path that is written AND DELETED — had to be added to both. Miss one
    /// and a test run sweeps the user's real data; there is precedent in this repo for exactly that.
    override func setUp() {
        super.setUp()
        // All tests run in Russian by default (historical expectations = Russian source text).
        activateLocalization("ru")
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
