import XCTest
import os
import AVFoundation
import AppKit
@testable import ParlaCore
@testable import Parla

/// Folder watching, the audio player, quick-transcribe from the pasteboard, and long-audio chunk planning/stitching.
final class FolderWatchPlaybackTests: ParlaLogicTestCase {
    // MARK: Long-audio chunking — planning + stitching + chapters (AudioChunker)

    func testChunkCount() {
        XCTAssertEqual(AudioChunker.chunkCount(durationSec: 0), 1)                        // empty → 1
        XCTAssertEqual(AudioChunker.chunkCount(durationSec: 120, chunkLength: 120), 1)    // exact 1
        XCTAssertEqual(AudioChunker.chunkCount(durationSec: 121, chunkLength: 120), 2)    // +1s → 2
        XCTAssertEqual(AudioChunker.chunkCount(durationSec: 240, chunkLength: 120), 2)    // exact 2
        XCTAssertEqual(AudioChunker.chunkCount(durationSec: 2400, chunkLength: 120), 20)  // 40 min → 20
    }

    func testIsLong() {
        XCTAssertFalse(AudioChunker.isLong(durationSec: 600))   // exactly 10 min is NOT long (strict >)
        XCTAssertTrue(AudioChunker.isLong(durationSec: 601))
        XCTAssertFalse(AudioChunker.isLong(durationSec: 0))
    }

    func testShouldChunkIsBatchIndependent() {
        XCTAssertTrue(AudioChunker.shouldChunk(durationSec: 700, chunkingAvailable: true))    // long + chunking → chunk (even in a batch)
        XCTAssertFalse(AudioChunker.shouldChunk(durationSec: 700, chunkingAvailable: false))  // no chunking → single-pass
        XCTAssertFalse(AudioChunker.shouldChunk(durationSec: 300, chunkingAvailable: true))   // short → single-pass
    }

    func testOffsetSegments() {
        let segs = [Segment(start: 0, end: 5, text: "a"), Segment(start: 5, end: 10, text: "b")]
        let offset = AudioChunker.offsetSegments(segs, chunkIndex: 2, chunkLength: 120)
        XCTAssertEqual(offset[0].start, 240)   // 2 * 120
        XCTAssertEqual(offset[0].end, 245)
        XCTAssertEqual(offset[1].start, 245)
        XCTAssertEqual(offset[0].text, "a")    // text unchanged
    }

    func testStitch() {
        let chunk0 = [Segment(start: 0, end: 60, text: "c0a"), Segment(start: 60, end: 119, text: "c0b")]
        let chunk1 = [Segment(start: 0, end: 60, text: "c1a")]
        let stitched = AudioChunker.stitch(chunkSegments: [chunk0, chunk1], chunkLength: 120)
        XCTAssertEqual(stitched.count, 3)
        XCTAssertEqual(stitched.map(\.text), ["c0a", "c0b", "c1a"])   // sorted by global start
        XCTAssertEqual(stitched[2].start, 120)                        // chunk1's local 0 → global 120
    }

    func testFailedChunkSegmentIsZeroWidthMarker() {
        let seg = AudioChunker.failedChunkSegment(label: "(chunk 3 failed)")
        XCTAssertEqual(seg.start, 0)
        XCTAssertEqual(seg.end, 0)                               // zero width → no fake 2-min span
        XCTAssertEqual(seg.text, "(chunk 3 failed)")
        // after stitching it lands at the chunk's start offset, still zero width
        let placed = AudioChunker.offsetSegments([seg], chunkIndex: 2, chunkLength: 120)[0]
        XCTAssertEqual(placed.start, 240)
        XCTAssertEqual(placed.end, 240)
    }

    func testResolveChunkedLanguage() {
        // first non-empty chunk language wins → Auto-detected language survives on long files
        XCTAssertEqual(AudioChunker.resolveLanguage(chunkLanguages: ["", "ru", "en"], requested: nil), "ru")
        // nothing detected (all chunks failed/silent) → fall back to the requested language
        XCTAssertEqual(AudioChunker.resolveLanguage(chunkLanguages: ["", ""], requested: "uk"), "uk")
        // nothing at all → empty (never crashes, mirrors single-pass default)
        XCTAssertEqual(AudioChunker.resolveLanguage(chunkLanguages: [], requested: nil), "")
    }

    func testChapters() {
        let segs = [
            Segment(start: 0, end: 60, text: "a"),
            Segment(start: 90, end: 119, text: "b"),     // same 0–120 window as "a"
            Segment(start: 130, end: 180, text: "c"),    // 120–240 window
        ]
        let chs = AudioChunker.chapters(from: segs, size: 120)
        XCTAssertEqual(chs.count, 2)
        XCTAssertEqual(chs[0].segments.map(\.text), ["a", "b"])
        XCTAssertEqual(chs[0].startSec, 0)
        XCTAssertEqual(chs[0].rangeLabel, "[00:00–02:00]")
        XCTAssertEqual(chs[1].segments.map(\.text), ["c"])
        XCTAssertEqual(chs[1].startSec, 120)
        XCTAssertEqual(chs[1].index, 1)
    }

    func testChaptersEmpty() {
        XCTAssertTrue(AudioChunker.chapters(from: [], size: 120).isEmpty)
    }


    // MARK: Folder watching (feature 04)

    func testFolderScanIgnoresUnstable() {
        let a = stat("a.ogg", 100, 1000)
        let bPrev = stat("b.ogg", 100, 1000)
        let bNow  = stat("b.ogg", 200, 1000)   // size grew → file is still being written
        let (ready, next) = FolderScan.newStableFiles(
            current: [a, bNow],
            lastSeen: ["/watch/a.ogg": a, "/watch/b.ogg": bPrev],
            processed: [])
        XCTAssertEqual(ready.map { $0.url.lastPathComponent }, ["a.ogg"])   // only the stable a
        XCTAssertEqual(next["/watch/b.ogg"], bNow)                          // b deferred to the next pass
    }

    func testFolderScanFirstSightNotReady() {
        let a = stat("a.ogg", 100, 1000)
        let (ready, next) = FolderScan.newStableFiles(current: [a], lastSeen: [:], processed: [])
        XCTAssertTrue(ready.isEmpty)               // seen for the first time — not ready yet
        XCTAssertEqual(next["/watch/a.ogg"], a)    // but remembered
    }

    func testFolderScanSkipsProcessed() {
        let a = stat("a.ogg", 100, 1000)
        let (ready, _) = FolderScan.newStableFiles(current: [a], lastSeen: ["/watch/a.ogg": a], processed: [a.dedupKey])
        XCTAssertTrue(ready.isEmpty)   // dedupKey already processed → skip
    }

    func testFolderScanReadyIsSorted() {
        let c = stat("c.ogg", 1, 1), a = stat("a.ogg", 1, 1), b = stat("b.ogg", 1, 1)
        let lastSeen = ["/watch/c.ogg": c, "/watch/a.ogg": a, "/watch/b.ogg": b]
        let (ready, _) = FolderScan.newStableFiles(current: [c, a, b], lastSeen: lastSeen, processed: [])
        XCTAssertEqual(ready.map { $0.url.lastPathComponent }, ["a.ogg", "b.ogg", "c.ogg"])
    }

    func testDedupKeyChangesWithContent() {
        let base = stat("a.ogg", 100, 1000)
        XCTAssertEqual(base.dedupKey, stat("a.ogg", 100, 1000).dedupKey)       // same triple → same key
        XCTAssertNotEqual(base.dedupKey, stat("a.ogg", 200, 1000).dedupKey)    // different size
        XCTAssertNotEqual(base.dedupKey, stat("a.ogg", 100, 2000).dedupKey)    // different mtime
    }

    func testCapProcessedFIFO() {
        XCTAssertEqual(FolderScan.capProcessed(["1", "2", "3", "4"], max: 2), ["3", "4"])  // oldest discarded
        XCTAssertEqual(FolderScan.capProcessed(["1"], max: 2), ["1"])                      // under the limit — unchanged
        XCTAssertEqual(FolderScan.capProcessed(["1", "2"], max: 0), [])
    }

    func testProcessedStoreRoundtrip() {
        let original = ProcessedStore.fileURL
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ParlaPS-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ProcessedStore.fileURL = dir.appendingPathComponent("processed.json")
        defer { ProcessedStore.fileURL = original; try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(ProcessedStore.load(), [])                    // no file → empty, no crash
        ProcessedStore.save(["k1", "k2", "k3"])
        XCTAssertEqual(ProcessedStore.load(), ["k1", "k2", "k3"])   // order preserved (needed for FIFO)
    }

    func testScanFolderRecursiveVsFlat() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: tmp.appendingPathComponent("a.ogg"))
        try Data("x".utf8).write(to: tmp.appendingPathComponent("note.txt"))
        try Data("x".utf8).write(to: tmp.appendingPathComponent("sub/b.mp3"))

        let flat = AppModel.scanFolder(tmp, recursive: false).map { $0.url.lastPathComponent }
        XCTAssertEqual(flat, ["a.ogg"])                                                  // no subfolders, no note.txt
        let rec = Set(AppModel.scanFolder(tmp, recursive: true).map { $0.url.lastPathComponent })
        XCTAssertEqual(rec, ["a.ogg", "b.mp3"])
    }

    func testScanFolderCapturesSizeAndMtime() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 1234).write(to: tmp.appendingPathComponent("a.ogg"))
        let stats = AppModel.scanFolder(tmp, recursive: false)
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats.first?.size, 1234)
        XCTAssertNotNil(stats.first?.mtime)
    }

    func testNewStableFilesEndToEnd() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 500).write(to: tmp.appendingPathComponent("a.ogg"))

        // first pass: file seen for the first time → not ready
        let pass1 = AppModel.scanFolder(tmp, recursive: false)
        let (ready1, seen1) = FolderScan.newStableFiles(current: pass1, lastSeen: [:], processed: [])
        XCTAssertTrue(ready1.isEmpty)
        // second pass with no changes → ready (two-pass stability guarantee, no FSEvents)
        let pass2 = AppModel.scanFolder(tmp, recursive: false)
        let (ready2, _) = FolderScan.newStableFiles(current: pass2, lastSeen: seen1, processed: [])
        XCTAssertEqual(ready2.map { $0.url.lastPathComponent }, ["a.ogg"])
    }


    // MARK: Audio player (feature 06)

    func testTranscriptItemDecodesWithoutAudioFile() throws {
        let legacy = #"[{"id":"\#(UUID().uuidString)","date":740000000,"sourceName":"a.ogg","language":"ru","durationSec":1,"model":"openai_whisper-tiny","text":"привет","segments":[]}]"#
        let items = try JSONDecoder().decode([TranscriptItem].self, from: Data(legacy.utf8))
        XCTAssertNil(items.first?.audioFile)        // no key → nil, NOT a throw
        XCTAssertNil(items.first?.audioPlayable)
        XCTAssertEqual(items.first?.text, "привет")
    }

    func testCodableRoundtripWithAudioFile() throws {
        var item = makeItem(text: "txt")
        item.audioFile = "X.ogg"
        item.audioPlayable = "X.m4a"
        let data = try JSONEncoder().encode([item])
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("audioFile") ?? false)
        let back = try JSONDecoder().decode([TranscriptItem].self, from: data)
        XCTAssertEqual(back.first?.audioFile, "X.ogg")
        XCTAssertEqual(back.first?.audioPlayable, "X.m4a")
    }

    func testAudioStoreFileName() {
        let id = UUID()
        XCTAssertEqual(AudioStore.fileName(for: id, sourceExtension: "OGG"), "\(id.uuidString).ogg")  // lowercased
        XCTAssertEqual(AudioStore.fileName(for: id, sourceExtension: "m4a"), "\(id.uuidString).m4a")
        XCTAssertEqual(AudioStore.fileName(for: id, sourceExtension: "MP3"), "\(id.uuidString).mp3")
        XCTAssertEqual(AudioStore.fileName(for: id, sourceExtension: ""),    "\(id.uuidString).bin")
    }

    func testAudioStoreCopyAndRemove() throws {
        withTemporaryHistoryStore {
            let fm = FileManager.default
            let src = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).ogg")
            try? Data("audio".utf8).write(to: src)
            defer { try? fm.removeItem(at: src) }

            let id = UUID()
            let name = AudioStore.copy(from: src, id: id)
            XCTAssertNotNil(name)
            var item = makeItem(text: "t")
            item.audioFile = name
            XCTAssertNotNil(AudioStore.playableURL(for: item))   // copy in place
            AudioStore.remove(item)
            XCTAssertNil(AudioStore.playableURL(for: item))      // removed
        }
    }

    func testAudioStoreUrlMissingReturnsNil() {
        withTemporaryHistoryStore {
            var item = makeItem(text: "t")
            item.audioFile = "nope-\(UUID().uuidString).ogg"     // no such file
            XCTAssertNil(AudioStore.playableURL(for: item))
        }
    }

    func testActiveSegmentIndex() {
        let segs = [Segment(start: 0, end: 2, text: "a"),
                    Segment(start: 2, end: 5, text: "b"),
                    Segment(start: 10, end: 12, text: "c")]
        XCTAssertNil(activeSegmentIndex(segs, at: -1))          // before the first
        XCTAssertEqual(activeSegmentIndex(segs, at: 0), 0)
        XCTAssertEqual(activeSegmentIndex(segs, at: 1.9), 0)
        XCTAssertEqual(activeSegmentIndex(segs, at: 2), 1)      // exactly start → new segment
        XCTAssertEqual(activeSegmentIndex(segs, at: 6), 1)      // in a gap → stay on the last one that started
        XCTAssertEqual(activeSegmentIndex(segs, at: 11), 2)
        XCTAssertEqual(activeSegmentIndex(segs, at: 100), 2)    // past the end → last
        XCTAssertNil(activeSegmentIndex([], at: 1))             // no segments
    }


    // MARK: Quick transcribe — pasteboard + hotkey (feature 03)

    func testPasteboardParseFileScheme() {
        XCTAssertEqual(PasteboardReader.parse(strings: ["file:///Users/me/v.ogg"]).map(\.path),
                       ["/Users/me/v.ogg"])
    }
    func testPasteboardParsePosixPath() {
        XCTAssertEqual(PasteboardReader.parse(strings: ["/tmp/a.m4a"]).first?.lastPathComponent, "a.m4a")
    }
    func testPasteboardParseTrimsWhitespace() {
        XCTAssertEqual(PasteboardReader.parse(strings: ["  /tmp/b.wav \n"]).first?.lastPathComponent, "b.wav")
    }
    func testPasteboardParseRejectsNonPaths() {
        XCTAssertTrue(PasteboardReader.parse(strings: ["привет мир", "", "https://x.com/a.ogg"]).isEmpty)
    }
    func testPasteboardParseEmpty() {
        XCTAssertTrue(PasteboardReader.parse(strings: []).isEmpty)
    }

    func testAudioOnlyKeepsAudioDropsOther() {
        let urls = [URL(fileURLWithPath: "/t/a.ogg"), URL(fileURLWithPath: "/t/b.pdf"),
                    URL(fileURLWithPath: "/t/c.M4A"), URL(fileURLWithPath: "/t/d.txt")]
        XCTAssertEqual(PasteboardReader.audioOnly(urls).map { $0.lastPathComponent }, ["a.ogg", "c.M4A"])  // case-insensitive, audio only
    }
    func testAudioOnlyEmpty() {
        XCTAssertTrue(PasteboardReader.audioOnly([]).isEmpty)
    }


}
