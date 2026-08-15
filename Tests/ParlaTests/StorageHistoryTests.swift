import XCTest
import os
import AVFoundation
import AppKit
@testable import ParlaCore
@testable import Parla

/// Everything that touches disk: the record schema, search, migration, the audio store and its LRU, sidecars, corruption resilience, and memory pressure.
final class StorageHistoryTests: ParlaLogicTestCase {
    // MARK: TranscriptItem

    func testDisplayPlain() {
        let item = makeItem(text: "привет мир", segments: [])
        XCTAssertEqual(item.display(timestamps: false), "привет мир")
        XCTAssertEqual(item.display(timestamps: true), "привет мир")   // no segments → fallback
    }

    func testDisplayTimestamps() {
        let segs = [Segment(start: 0, end: 2, text: "привет"), Segment(start: 65, end: 67, text: "мир")]
        let item = makeItem(text: "привет мир", segments: segs)
        XCTAssertEqual(item.display(timestamps: true), "[00:00] привет\n[01:05] мир")
        XCTAssertEqual(item.display(timestamps: false), "привет мир")
    }

    func testWordCount() {
        XCTAssertEqual(makeItem(text: "привет мир как дела").wordCount, 4)
        XCTAssertEqual(makeItem(text: "  один  ").wordCount, 1)
        XCTAssertEqual(makeItem(text: "").wordCount, 0)
        XCTAssertEqual(makeItem(text: "строка\nдве слова").wordCount, 3)
    }

    func testCodableRoundtrip() throws {
        let item = makeItem(text: "txt", segments: [Segment(start: 0, end: 1, text: "x")])
        let data = try JSONEncoder().encode([item])
        let back = try JSONDecoder().decode([TranscriptItem].self, from: data)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].id, item.id)
        XCTAssertEqual(back[0].text, "txt")
        XCTAssertEqual(back[0].segments.first?.text, "x")
        XCTAssertEqual(back[0].model, item.model)
    }


    // MARK: History — search

    func testFilterHistory() {
        let items = [
            makeItem(name: "a.ogg", text: "привет мир"),
            makeItem(name: "b.ogg", text: "пока всем"),
            makeItem(name: "secret.ogg", text: "ничего"),
        ]
        XCTAssertEqual(filterHistory(items, query: "").count, 3)       // empty query → all
        XCTAssertEqual(filterHistory(items, query: "  ").count, 3)     // whitespace → all
        XCTAssertEqual(filterHistory(items, query: "мир").count, 1)    // by text
        XCTAssertEqual(filterHistory(items, query: "ПРИВЕТ").count, 1) // case-insensitive
        XCTAssertEqual(filterHistory(items, query: "secret").count, 1) // by file name
        XCTAssertEqual(filterHistory(items, query: "неттакого").count, 0)
        // Morphology path: with a lemma index, a query lemma matches even with no substring hit anywhere.
        let lemmas = [items[2].id: Set(["тайна"])]                       // secret.ogg ("ничего") tagged with «тайна»
        XCTAssertEqual(filterHistory(items, query: "тайна", lemmaIndex: lemmas).map(\.id), [items[2].id])
        XCTAssertTrue(filterHistory(items, query: "тайна").isEmpty)      // no index → substring only → nothing
    }


    func testLemmaSet() throws {
        try XCTSkipUnless(hasRussianLemmatizer, "Russian NLTagger lemma asset unavailable on this host")
        let s = lemmaSet(of: "Обсудили проекты и работу команды", language: "ru")
        XCTAssertTrue(s.contains("проект"))   // проекты → проект
        XCTAssertTrue(s.contains("работа"))   // работу → работа
        XCTAssertFalse(s.contains("и"))       // ≤2 chars dropped as noise
        XCTAssertTrue(lemmaSet(of: "   ").isEmpty)
    }


    // MARK: History — Murmur → Parla migration

    func testMigrationCopiesWhenTargetMissing() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        let legacy = tmp.appendingPathComponent("Murmur/history.json")
        let target = tmp.appendingPathComponent("Parla/history.json")
        try fm.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: legacy)

        HistoryStore.migrate(target: target, legacy: legacy)
        XCTAssertTrue(fm.fileExists(atPath: target.path))

        try Data("[1,2,3]".utf8).write(to: legacy)  // run again — does not overwrite
        HistoryStore.migrate(target: target, legacy: legacy)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "[]")
    }

    func testMigrationNoopWhenLegacyMissing() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        let target = tmp.appendingPathComponent("Parla/history.json")
        HistoryStore.migrate(target: target, legacy: tmp.appendingPathComponent("Murmur/history.json"))
        XCTAssertFalse(fm.fileExists(atPath: target.path))
    }


    // MARK: FolderWatcher teardown stress

    /// Exercises the passRetained/release teardown deterministically (no event-timing dependency):
    /// a UAF or over-release in start()/stop() would trap, so reaching the end is the assertion.
    @MainActor func testFolderWatcherStartStopStressNoCrash() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let w = FolderWatcher(folder: dir, recursive: true, debounce: 0.05) {}
        for _ in 0..<8 { w.start(); w.stop() }   // each start +1 (passRetained), each stop releases the stream → balanced
        w.start(); w.stop()
        w.stop()                                  // double stop is a safe no-op
        XCTAssertTrue(true)
    }

    @MainActor func testFolderWatcherPollingStartStopNoCrash() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let w = FolderWatcher(folder: dir, recursive: false, usePolling: true, debounce: 0.05) {}
        w.start()   // schedules the poll timer on main
        w.stop()    // invalidates it
        XCTAssertTrue(true)
    }


    // MARK: AudioStore round-trip

    func testAudioStorePlayableURLPrefersRendition() {
        withTemporaryHistoryStore {
            let id = UUID()
            let folder = AudioStore.folder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let orig = folder.appendingPathComponent("\(id).m4a")
            let rendition = folder.appendingPathComponent("\(id)-r.m4a")
            try? Data("o".utf8).write(to: orig)
            try? Data("r".utf8).write(to: rendition)
            var item = makeItem(text: "t")
            item.audioFile = orig.lastPathComponent
            item.audioPlayable = rendition.lastPathComponent

            // Prefers the m4a rendition (audioPlayable) when present…
            XCTAssertEqual(AudioStore.playableURL(for: item)?.lastPathComponent, rendition.lastPathComponent)
            // …and falls back to the original copy when the rendition is gone.
            try? FileManager.default.removeItem(at: rendition)
            XCTAssertEqual(AudioStore.playableURL(for: item)?.lastPathComponent, orig.lastPathComponent)
        }
    }

    func testAudioStorePruneOrphansRemovesUnreferenced() {
        withTemporaryHistoryStore {
            let folder = AudioStore.folder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let kept = UUID(), orphan = UUID()
            let keptFile = folder.appendingPathComponent("\(kept).m4a")
            let orphanFile = folder.appendingPathComponent("\(orphan).m4a")
            try? Data("k".utf8).write(to: keptFile)
            try? Data("o".utf8).write(to: orphanFile)
            var item = makeItem(text: "t")
            item.audioFile = keptFile.lastPathComponent

            AudioStore.pruneOrphans(keeping: [item])

            XCTAssertTrue(FileManager.default.fileExists(atPath: keptFile.path))     // referenced → kept
            XCTAssertFalse(FileManager.default.fileExists(atPath: orphanFile.path))  // unreferenced → removed
        }
    }

    // Full-review D6/S4 + D8: pruneImportedSource does a RECURSIVE removeItem, guarded ONLY by a prefix check that it
    // stays within Application Support/Parla/imports/. Pin BOTH branches — a weakened guard would delete a dir OUTSIDE
    // imports/ (a macOS original's parent, an AV-native drop). The root IS injectable now — `AppModel.importsRoot`
    // is redirected to a throwaway dir in setUp, so this exercises a recursive delete without ever pointing it at
    // the user's real container. (It used to build these fixtures in the real one.)
    func testPruneImportedSourceOnlyDeletesUnderImports() throws {
        let fm = FileManager.default
        let importsRoot = AppModel.importsRoot
        try fm.createDirectory(at: importsRoot, withIntermediateDirectories: true)

        // (1) A Parla-managed import dir → the whole <uuid> dir is removed.
        let importDir = importsRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: importDir, withIntermediateDirectories: true)
        let importFile = importDir.appendingPathComponent("voice.ogg")
        try Data("x".utf8).write(to: importFile)
        defer { try? fm.removeItem(at: importDir) }
        AppModel.pruneImportedSource(importFile.path)
        XCTAssertFalse(fm.fileExists(atPath: importDir.path), "a Parla-managed import dir is removed")

        // (2) SAFETY: a source OUTSIDE imports/ (macOS original / AV-native drop) → the dir is NEVER touched.
        let outside = fm.temporaryDirectory.appendingPathComponent("orig-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("original.ogg")
        try Data("x".utf8).write(to: outsideFile)
        defer { try? fm.removeItem(at: outside) }
        AppModel.pruneImportedSource(outsideFile.path)
        XCTAssertTrue(fm.fileExists(atPath: outside.path), "a source outside imports/ is never deleted (guard holds)")
        XCTAssertTrue(fm.fileExists(atPath: outsideFile.path))

        // (3) nil path → no crash, no-op.
        AppModel.pruneImportedSource(nil)
    }

    // Full-review D6/S4 + D8: the launch orphan sweep removes only UNreferenced import dirs — a saved note's copy is
    // KEPT (re-transcribe/replay need it), an abandoned failed/cancelled/crashed copy is swept. Recursive delete → pin.
    func testPruneImportedOrphansRemovesOnlyUnreferenced() throws {
        let fm = FileManager.default
        let root = AppModel.importsRoot        // redirected in setUp — never the user's real container
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let keptDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let orphanDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: keptDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        let keptFile = keptDir.appendingPathComponent("voice.ogg")
        try Data("x".utf8).write(to: keptFile)
        try Data("x".utf8).write(to: orphanDir.appendingPathComponent("orphan.ogg"))
        defer { try? fm.removeItem(at: keptDir); try? fm.removeItem(at: orphanDir) }

        var item = makeItem(text: "t")
        item.sourcePath = keptFile.path

        // now = a week and a day past the dirs' mtime → both are past the grace period, so only the
        // reference-check decides. (The grace period itself is pinned by the two tests below.)
        AppModel.pruneImportedOrphans(keeping: [item], now: Date().addingTimeInterval(694_800))

        XCTAssertTrue(fm.fileExists(atPath: keptDir.path), "a saved note's import copy is kept")
        XCTAssertFalse(fm.fileExists(atPath: orphanDir.path), "an unreferenced import copy is swept")
    }

    /// THE data-loss guard. A drop stopped by a Pro gate (batch, or the free length cap) produces no note, so its
    /// import copy is "unreferenced" — while being the user's ONLY copy, because `ShareInbox.drain` has already
    /// cleared the share inbox. Two voice notes shared from Telegram by a free user were paywalled and then, on
    /// the next launch, deleted; buying Pro afterwards could not bring them back.
    func testPruneImportedOrphansKeepsARecentUnreferencedCopyPendingAnUpgradeOrRetry() throws {
        let fm = FileManager.default
        let root = AppModel.importsRoot        // redirected in setUp — never the user's real container
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let gatedDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: gatedDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: gatedDir.appendingPathComponent("voice.ogg"))
        defer { try? fm.removeItem(at: gatedDir) }

        AppModel.pruneImportedOrphans(keeping: [])   // just shared, just paywalled, nothing in history

        XCTAssertTrue(fm.fileExists(atPath: gatedDir.path),
                      "a copy imported moments ago is the user's only one — it must survive the launch sweep")
    }

    /// …but the grace period must expire, or a crash between copy and save leaks bytes forever.
    func testPruneImportedOrphansStillSweepsOnceTheGracePeriodHasPassed() throws {
        let fm = FileManager.default
        let root = AppModel.importsRoot        // redirected in setUp — never the user's real container
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let deadDir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: deadDir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: deadDir.appendingPathComponent("voice.ogg"))
        defer { try? fm.removeItem(at: deadDir) }

        AppModel.pruneImportedOrphans(keeping: [], now: Date().addingTimeInterval(694_800))   // 8 days on

        XCTAssertFalse(fm.fileExists(atPath: deadDir.path), "past the grace period an unreferenced copy is swept")
    }


    // MARK: The destructive import root must never point at the user's container during a test run

    /// `pruneImportedOrphans` recursively removes every unreferenced subdirectory of the imports root, and until
    /// now that root was hardcoded — so these very tests built their fixtures inside
    /// `~/Library/Application Support/Parla/imports` and swept it with `keeping: []`. It was survivable only
    /// because macOS happens to put nothing there; the day it does, or the day these run against a populated
    /// container, a test deletes a user's files. This project has already lost real data to exactly this shape.
    func testTheDestructiveImportRootIsRedirectedAwayFromTheUsersContainer() {
        XCTAssertNotEqual(AppModel.importsRoot, AppModel.defaultImportsRoot(),
                          "setUp must redirect importsRoot — a destructive sweep may never run on the real container")
        XCTAssertFalse(AppModel.importsRoot.path.contains("Application Support/Parla/imports"),
                       "…and the redirect must not merely alias the production path")
    }


    // MARK: History resilience — one corrupt record must NOT wipe the archive (data-loss fix)

    private func validRecordJSON(text: String) -> String {
        #"{"id":"\#(UUID().uuidString)","date":1,"sourceName":"a.ogg","language":"ru","durationSec":1,"model":"m","text":"\#(text)","segments":[]}"#
    }
    private var corruptSiblings: [URL] {
        let dir = HistoryStore.fileURL.deletingLastPathComponent()
        return (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("history.corrupt-") } ?? []
    }

    func testFailableDecodableDropsBadElement() {
        let json = "[\(validRecordJSON(text: "hi")),{\"language\":\"ru\"}]"   // one valid + one missing required keys
        let arr = try? JSONDecoder().decode([FailableDecodable<TranscriptItem>].self, from: Data(json.utf8))
        XCTAssertEqual(arr?.compactMap(\.value).count, 1)
    }

    func testLoadSkipsCorruptRecordKeepsValidOnes() {
        withTemporaryHistoryStore {
            let json = "[\(validRecordJSON(text: "hi")),{\"language\":\"ru\"}]"
            try? Data(json.utf8).write(to: HistoryStore.fileURL)
            let items = HistoryStore.load()
            XCTAssertEqual(items.count, 1)               // valid record survived
            XCTAssertEqual(items.first?.text, "hi")
            XCTAssertFalse(corruptSiblings.isEmpty)       // raw bytes quarantined for recovery
        }
    }

    func testLoadQuarantinesUnparseableFileAndReturnsEmpty() {
        withTemporaryHistoryStore {
            try? Data("this is not json at all".utf8).write(to: HistoryStore.fileURL)
            let items = HistoryStore.load()
            XCTAssertTrue(items.isEmpty)
            XCTAssertFalse(corruptSiblings.isEmpty)       // unparseable bytes preserved, not silently lost
        }
    }

    func testLoadEmptyArrayIsNotQuarantined() {
        withTemporaryHistoryStore {
            try? Data("[]".utf8).write(to: HistoryStore.fileURL)
            let items = HistoryStore.load()
            XCTAssertTrue(items.isEmpty)
            XCTAssertTrue(corruptSiblings.isEmpty)        // a legitimately-empty history is NOT corruption
        }
    }


    // MARK: Sidecar identity + migration completeness (C, D)

    func testSidecarMatchesBySourcePathNotName() {
        var a = makeItem(name: "voice.ogg", text: "AAA"); a.sourcePath = "/a/voice.ogg"
        var b = makeItem(name: "voice.ogg", text: "BBB"); b.sourcePath = "/b/voice.ogg"
        let history = [b, a]   // same filename, different folders; newest first (would mis-match by name)
        XCTAssertEqual(AppModel.sidecarTarget(in: history, for: URL(fileURLWithPath: "/b/voice.ogg"))?.text, "BBB")
        XCTAssertEqual(AppModel.sidecarTarget(in: history, for: URL(fileURLWithPath: "/a/voice.ogg"))?.text, "AAA")
        XCTAssertNil(AppModel.sidecarTarget(in: history, for: URL(fileURLWithPath: "/c/voice.ogg")))
    }

    func testSidecarURLKeepsAudioExtension() {
        // voice.ogg → voice.ogg.txt (not voice.txt): distinct per audio file, can't hit a user's voice.txt
        XCTAssertEqual(AppModel.sidecarURL(for: URL(fileURLWithPath: "/w/voice.ogg")).lastPathComponent, "voice.ogg.txt")
        // same basename, different audio extension → DISTINCT sidecars (no last-writer-wins collision)
        XCTAssertNotEqual(AppModel.sidecarURL(for: URL(fileURLWithPath: "/w/voice.ogg")),
                          AppModel.sidecarURL(for: URL(fileURLWithPath: "/w/voice.opus")))
    }

    func testSidecarPlanNeverClobbersExisting() {
        // target already exists (a user's own file) → skip, return nil (no overwrite)
        XCTAssertNil(AppModel.sidecarPlan(text: "transcript", targetExists: true))
        // no file there → write the transcript
        XCTAssertEqual(AppModel.sidecarPlan(text: "transcript", targetExists: false), Data("transcript".utf8))
    }

    func testStoreFileURLSeamsSwapAndRestore() {
        // The nonisolated(unsafe) test seams (Swift 6 flip) must still swap + restore verbatim —
        // withTemporaryHistoryStore and every orchestration test rely on this contract.
        let origHistory = HistoryStore.fileURL
        let origProcessed = ProcessedStore.fileURL
        let tmpH = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        let tmpP = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json")
        HistoryStore.fileURL = tmpH
        ProcessedStore.fileURL = tmpP
        XCTAssertEqual(HistoryStore.fileURL, tmpH)
        XCTAssertEqual(ProcessedStore.fileURL, tmpP)
        HistoryStore.fileURL = origHistory
        ProcessedStore.fileURL = origProcessed
        XCTAssertEqual(HistoryStore.fileURL, origHistory)
        XCTAssertEqual(ProcessedStore.fileURL, origProcessed)
    }

    func testMigrateClearsStaleStagingAndCopiesFresh() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mig-\(UUID().uuidString)")
        let legacy = root.appendingPathComponent("history.json")
        let target = root.appendingPathComponent("Parla/history.json")
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("real".utf8).write(to: legacy)
        let stale = target.appendingPathExtension("migrating")
        try Data("garbage from a prior crash".utf8).write(to: stale)   // leftover partial copy
        defer { try? fm.removeItem(at: root) }

        HistoryStore.migrate(target: target, legacy: legacy)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "real")   // fresh copy, not the stale partial
        XCTAssertFalse(fm.fileExists(atPath: stale.path))                          // staging cleaned up after rename
    }

    func testMigrateDirCopiesWhenTargetMissingAndIsIdempotent() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mig-\(UUID().uuidString)")
        let legacy = root.appendingPathComponent("audio", isDirectory: true)
        let target = root.appendingPathComponent("Parla/audio", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: legacy.appendingPathComponent("a.m4a"))
        defer { try? fm.removeItem(at: root) }

        HistoryStore.migrateDir(target: target, legacy: legacy)
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("a.m4a").path))   // dir copied
        HistoryStore.migrateDir(target: target, legacy: legacy)                              // re-run = no-op
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("a.m4a").path))
    }

    func testMigrateDirNoopWhenLegacyMissing() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("mig-\(UUID().uuidString)")
        let target = root.appendingPathComponent("Parla/audio", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        HistoryStore.migrateDir(target: target, legacy: root.appendingPathComponent("nope", isDirectory: true))
        XCTAssertFalse(fm.fileExists(atPath: target.path))   // nothing to copy → no target created
    }


    // MARK: Audio cache auto-cleanup (LRU)

    func testEnforceAudioCapNoOpUnderCap() {
        let a = makeItem(text: "a"), b = makeItem(text: "b")
        let sizes = [a.id: Int64(100), b.id: Int64(100)]
        let evict = AudioStore.enforceAudioCap([b, a], capBytes: 1000, sizeOf: { sizes[$0.id] ?? 0 }, protected: [])
        XCTAssertTrue(evict.isEmpty)   // we fit → don't touch anything
    }

    func testEnforceAudioCapEvictsOldest() {
        let n = makeItem(text: "n"), m = makeItem(text: "m"), o = makeItem(text: "o")   // newest-first: [n, m, o]
        let sizes = [n.id: Int64(400), m.id: Int64(400), o.id: Int64(400)]               // 1200 > 1000
        let evict = AudioStore.enforceAudioCap([n, m, o], capBytes: 1000, sizeOf: { sizes[$0.id] ?? 0 }, protected: [])
        XCTAssertEqual(evict, [o.id])   // only the oldest, until it fits (1200-400=800 ≤ 1000)
    }

    func testEnforceAudioCapProtectsSelected() {
        let n = makeItem(text: "n"), m = makeItem(text: "m"), o = makeItem(text: "o")
        let sizes = [n.id: Int64(400), m.id: Int64(400), o.id: Int64(400)]
        let evict = AudioStore.enforceAudioCap([n, m, o], capBytes: 1000, sizeOf: { sizes[$0.id] ?? 0 }, protected: [o.id])
        XCTAssertEqual(evict, [m.id])   // o is protected (playing/selected) → evict the next oldest
    }

    func testEnforceAudioCapSkipsItemsWithoutAudio() {
        let n = makeItem(text: "n"), m = makeItem(text: "m"), o = makeItem(text: "o")
        let sizes = [n.id: Int64(600), o.id: Int64(600)]   // m has no audio (0 bytes)
        let evict = AudioStore.enforceAudioCap([n, m, o], capBytes: 1000, sizeOf: { sizes[$0.id] ?? 0 }, protected: [])
        XCTAssertEqual(evict, [o.id])   // 1200>1000 → evict o (600≤1000); m skipped (no audio)
    }

    func testEnforceAudioCapPartialWhenOnlyProtectedExceeds() {
        let big = makeItem(text: "big")
        let sizes = [big.id: Int64(2000)]   // a single entry exceeds the whole cap, but it's protected
        let evict = AudioStore.enforceAudioCap([big], capBytes: 1000, sizeOf: { sizes[$0.id] ?? 0 }, protected: [big.id])
        XCTAssertTrue(evict.isEmpty)   // don't yank audio out from under the player — partial compliance is OK
    }

    /// The one above is a ONE-item history, so it cannot tell correct behaviour apart from the bug: with nothing
    /// else present there is nothing to evict either way. Give the protected over-cap item some company and the
    /// real question appears — does an unreachable target make the loop strip everyone else?
    ///
    /// Live case: a Pro user imports a 1-hour video. `keepAudio` stores the full container AND a rendered .m4a,
    /// so one note can pass the 500 MB default cap on its own; `transcribe` has already selected it, so it is the
    /// protected one. The whole back catalogue must not lose its player audio because of that.
    func testEnforceAudioCapDoesNotStripEveryoneElseWhenTheProtectedItemAloneExceedsTheCap() {
        let big = makeItem(text: "big"), a = makeItem(text: "a"), b = makeItem(text: "b")
        let sizes = [big.id: Int64(2000), a.id: Int64(100), b.id: Int64(100)]   // big alone > cap
        let evict = AudioStore.enforceAudioCap([big, a, b], capBytes: 1000,
                                               sizeOf: { sizes[$0.id] ?? 0 }, protected: [big.id])
        XCTAssertTrue(evict.isEmpty,
                      "the cap is unreachable while big is protected — evicting a and b cannot help, it only destroys their playback audio")
    }

    /// The eviction must still do its job when the cap IS reachable without touching the protected item.
    func testEnforceAudioCapStillEvictsWhenTheCapIsReachableAroundTheProtectedItem() {
        let n = makeItem(text: "n"), m = makeItem(text: "m"), o = makeItem(text: "o")
        let sizes = [n.id: Int64(400), m.id: Int64(400), o.id: Int64(400)]   // 1200 > 1000, protected is only 400
        let evict = AudioStore.enforceAudioCap([n, m, o], capBytes: 1000,
                                               sizeOf: { sizes[$0.id] ?? 0 }, protected: [n.id])
        XCTAssertEqual(evict, [o.id], "dropping the oldest is enough to fit — do that, and stop")
    }


// MARK: - Memory pressure


    /// `WhisperKit.unloadModels()` existed from day one and was called NOWHERE — the model stayed resident for
    /// the life of the process. The policy is now: give the weights back when the SYSTEM asks, never mid-job.
    @MainActor
    func testReleaseIdleMemoryUnloadsTheEngineWhenNothingIsRunning() async {
        let engine = FakeEngine()
        let m = AppModel(engine: engine, ai: FakeAIService(availabilityToReturn: .modelUnavailable))
        XCTAssertFalse(m.isBusy, "precondition: idle")

        await m.releaseIdleMemory()
        XCTAssertEqual(engine.unloadCalls, 1, "an idle app must hand the model's memory back under pressure")
    }

    /// The half that protects the user: unloading mid-job would abort or badly stall a running transcription.
    @MainActor
    func testReleaseIdleMemoryLeavesTheEngineAloneWhileBusy() async {
        let engine = FakeEngine()
        let m = AppModel(engine: engine, ai: FakeAIService(availabilityToReturn: .modelUnavailable))
        m.recordingStartedAt = Date()          // dictation in flight → isBusy
        XCTAssertTrue(m.isBusy, "precondition: busy")

        await m.releaseIdleMemory()
        XCTAssertEqual(engine.unloadCalls, 0, "never yank the model out from under a running job")

        m.recordingStartedAt = nil
        await m.releaseIdleMemory()
        XCTAssertEqual(engine.unloadCalls, 1, "…and release it once the job is done")
    }

}
