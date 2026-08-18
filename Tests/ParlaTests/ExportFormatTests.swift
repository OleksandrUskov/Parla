import XCTest
import os
import AVFoundation
import AppKit
@testable import ParlaCore
@testable import Parla

/// Getting text out: TXT/MD/SRT/VTT/JSON, insights in exports, read-aloud, and WhisperKit token cleanup.
final class ExportFormatTests: ParlaLogicTestCase {
    // MARK: Export menu labels

    /// The export menu is the one place a format name reaches the user, and it became worth localizing the day
    /// a fresh install started opening in the system's language rather than always English.
    ///
    /// The second half is the deliberate part, not an oversight: Markdown, SubRip, WebVTT and JSON are the
    /// formats' own names and are written identically in Russian and Ukrainian. Keys for them would be three
    /// identical strings each, guarded by a parity test that could never fail meaningfully.
    func testOnlyThePlainTextLabelIsALocalizablePhrase() {
        activateLocalization("ru")
        XCTAssertEqual(ExportFormat.txt.displayName, "Обычный текст (.txt)")
        activateLocalization("uk")
        XCTAssertEqual(ExportFormat.txt.displayName, "Звичайний текст (.txt)")
        activateLocalization("en")
        XCTAssertEqual(ExportFormat.txt.displayName, "Plain text (.txt)")

        for lang in ["en", "ru", "uk"] {
            activateLocalization(lang)
            XCTAssertEqual(ExportFormat.markdown.displayName, "Markdown (.md)", "format names do not translate")
            XCTAssertEqual(ExportFormat.srt.displayName, "SubRip (.srt)")
            XCTAssertEqual(ExportFormat.vtt.displayName, "WebVTT (.vtt)")
            XCTAssertEqual(ExportFormat.json.displayName, "JSON (.json)")
        }
    }

    // MARK: History — export

    func testExportText() {
        let items = [makeItem(name: "a.ogg", text: "первый"), makeItem(name: "b.ogg", text: "второй")]
        let out = exportText(items)
        XCTAssertTrue(out.hasPrefix("# Parla"))
        XCTAssertTrue(out.contains("## a.ogg"))
        XCTAssertTrue(out.contains("первый"))
        XCTAssertTrue(out.contains("второй"))
        XCTAssertEqual(exportText([]).hasPrefix("# Parla"), true)
    }


    // MARK: TTS — voice synthesis P1a (seam + system voice)

    /// Pure voice-language filter: 2-letter-prefix match, empty → all, no-match → empty.
    func testVoiceSelectionFilter() {
        let voices = [
            VoiceDescriptor(id: "a", name: "Milena", language: "ru-RU", isSystem: true),
            VoiceDescriptor(id: "b", name: "Lesya",  language: "uk-UA", isSystem: true),
            VoiceDescriptor(id: "c", name: "Samantha", language: "en-US", isSystem: true),
            VoiceDescriptor(id: "d", name: "Daniel", language: "en-GB", isSystem: true),
        ]
        XCTAssertEqual(VoiceSelection.filter(voices, language: "ru").map(\.id), ["a"])          // ru → ru-RU
        XCTAssertEqual(VoiceSelection.filter(voices, language: "ru-RU").map(\.id), ["a"])       // full tag → prefix
        XCTAssertEqual(VoiceSelection.filter(voices, language: "en").map(\.id), ["c", "d"])     // both en variants
        XCTAssertEqual(VoiceSelection.filter(voices, language: "").count, 4)                    // empty → all
        XCTAssertTrue(VoiceSelection.filter(voices, language: "de").isEmpty)                    // no match → none
    }

    /// The system backend exposes real voices structurally (every returned voice matches the language + isSystem).
    /// EN always exists on macOS, so it's a safe non-empty probe without pinning a specific voice name.
    func testSystemTTSVoices() {
        let en = SystemTTSService().voices(forLanguage: "en")
        XCTAssertFalse(en.isEmpty, "macOS always ships EN system voices")
        XCTAssertTrue(en.allSatisfy { $0.language.lowercased().hasPrefix("en") && $0.isSystem })
        XCTAssertEqual(SystemTTSService().availability(forLanguage: "en"), .ready)
        // A bogus language has no system voice → unsupported (drives the availability gate).
        XCTAssertEqual(SystemTTSService().availability(forLanguage: "zz"), .unsupported)
    }

    /// The test double filters its canned voices + reports the configured availability (no real synthesis).
    func testNoopTTS() async {
        let noop = NoopTTSService(availabilityToReturn: .ready,
                                  cannedVoices: [VoiceDescriptor(id: "x", name: "X", language: "ru-RU", isSystem: false)])
        XCTAssertEqual(noop.voices(forLanguage: "ru").map(\.id), ["x"])
        XCTAssertTrue(noop.voices(forLanguage: "en").isEmpty)
        XCTAssertEqual(noop.availability(forLanguage: "ru"), .ready)
        do { _ = try await noop.synthesize("hi", voice: VoiceDescriptor(id: "x", name: "X", language: "ru-RU", isSystem: false)); XCTFail("noop must not synthesize") }
        catch {}
    }


    // MARK: Export formats — SRT / VTT / JSON / TXT / MD (EXPORT_FORMATS P1)

    func testSRTTimecode() {
        XCTAssertEqual(srtTimecode(0), "00:00:00,000")
        XCTAssertEqual(srtTimecode(3661.5), "01:01:01,500")
        XCTAssertEqual(srtTimecode(-5), "00:00:00,000")        // negatives clamp
        XCTAssertEqual(srtTimecode(1.2345), "00:00:01,235")    // rounds, not floors (1234.5 → 1235)
    }

    func testVTTTimecode() {
        XCTAssertEqual(vttTimecode(0), "00:00:00.000")
        XCTAssertEqual(vttTimecode(3661.5), "01:01:01.500")
    }

    func testSubtitleTimecodeHandlesNonFinite() {
        // NaN/±inf must NOT trap Int(_:) and kill the export — clamp to zero
        XCTAssertEqual(srtTimecode(.nan), "00:00:00,000")
        XCTAssertEqual(srtTimecode(.infinity), "00:00:00,000")
        XCTAssertEqual(vttTimecode(-.infinity), "00:00:00.000")
    }

    func testCollapseBlankLines() {
        XCTAssertEqual(collapseBlankLines("a\n\nb"), "a\nb")       // blank line → single break
        XCTAssertEqual(collapseBlankLines("a\n \nb"), "a\nb")      // whitespace-only line too
        XCTAssertEqual(collapseBlankLines("a\n\n\nb"), "a\nb")     // run of blanks
        XCTAssertEqual(collapseBlankLines("a\nb"), "a\nb")         // single break preserved
        XCTAssertEqual(collapseBlankLines("solo"), "solo")
    }

    func testExportEditedCueHasNoBlankLine() {
        // an edited transcript with a paragraph break must not break SRT/VTT cue framing
        let item = makeItem(text: "line one\n\nline two", segments: [], edited: true)
        XCTAssertEqual(exportSRT(item), "1\n00:00:00,000 --> 00:00:01,000\nline one\nline two\n\n")
        XCTAssertFalse(exportSRT(item).contains("line one\n\nline two"))
        XCTAssertTrue(exportVTT(item).contains("line one\nline two\n"))
    }

    func testExportSRT() {
        let item = makeItem(text: "full", segments: [
            Segment(start: 0, end: 2, text: "first"),
            Segment(start: 2, end: 4, text: "second"),
        ])
        XCTAssertEqual(exportSRT(item),
            "1\n00:00:00,000 --> 00:00:02,000\nfirst\n\n" +
            "2\n00:00:02,000 --> 00:00:04,000\nsecond\n\n")
    }

    func testExportSRTSkipsEmptySegments() {
        let item = makeItem(text: "full", segments: [
            Segment(start: 0, end: 1, text: "a"),
            Segment(start: 1, end: 2, text: ""),       // dropped
            Segment(start: 2, end: 3, text: "b"),
        ])
        let srt = exportSRT(item)
        XCTAssertTrue(srt.contains("1\n00:00:00,000 --> 00:00:01,000\na\n\n"))
        XCTAssertTrue(srt.contains("2\n00:00:02,000 --> 00:00:03,000\nb\n\n"))
        XCTAssertFalse(srt.contains("3\n"))            // indices stay contiguous 1,2 (not 1,3)
    }

    func testExportVTT() {
        let item = makeItem(text: "full", segments: [Segment(start: 0, end: 2, text: "hi")])
        let vtt = exportVTT(item)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(vtt.contains("00:00:00.000 --> 00:00:02.000\nhi\n"))
        XCTAssertFalse(vtt.contains("\n1\n"))          // no integer cue index in VTT
    }

    func testExportJSONRoundtrips() throws {
        let item = makeItem(text: "data", segments: [Segment(start: 0, end: 1, text: "x")], edited: true)
        let data = try exportJSON(item)
        let back = try JSONDecoder().decode(TranscriptItem.self, from: data)
        XCTAssertEqual(back, item)                      // real Codable round-trip (default date enc → exact)
        XCTAssertEqual(try exportJSON(item), data)      // deterministic bytes (sorted keys)
    }

    func testExportPlainTXTFlatVsTimestamped() {
        let item = makeItem(text: "привет мир", segments: [
            Segment(start: 0, end: 1, text: "привет"),
            Segment(start: 1, end: 2, text: "мир"),
        ])
        XCTAssertEqual(exportPlainTXT(item, timestamps: false), "привет мир")
        XCTAssertEqual(exportPlainTXT(item, timestamps: true), "[00:00] привет\n[00:01] мир")
    }

    func testExportMarkdownSingleItem() {
        let item = makeItem(name: "talk.ogg", text: "body", lang: "ru", model: "openai_whisper-large-v3")
        let md = exportMarkdown(item)
        XCTAssertTrue(md.hasPrefix("## talk.ogg\n"))
        XCTAssertTrue(md.contains("· RU · Large v3"))
        XCTAssertTrue(md.contains("\n\nbody\n"))
        XCTAssertFalse(md.contains("---"))             // no between-records separator for a single item
    }


    // MARK: insights in export (opt-in; SRT skipped, JSON already carries them)

    /// The insight header is fully Optional-gated: a note with NO insight fields contributes nothing, so an
    /// insight-less export stays byte-identical to pre-P4 (this is what keeps the existing byte-pin tests valid).
    func testInsightBlockEmptyWhenNoInsights() {
        let bare = makeItem(text: "body")   // no title/summary/keywords/actions
        XCTAssertEqual(insightBlock(bare, markdown: true), "")
        XCTAssertEqual(insightBlock(bare, markdown: false), "")
    }

    func testExportMarkdownIncludesInsights() {
        var it = makeItem(name: "talk.ogg", text: "body text", lang: "ru", model: "openai_whisper-large-v3")
        it.title = "Мой заголовок"; it.summary = "Краткая сводка"; it.keywords = ["один", "два"]
        it.actions = [ActionItem(text: "Позвонить"), ActionItem(text: "Готово", done: true)]
        let md = exportMarkdown(it, content: .withInsights)
        XCTAssertTrue(md.contains("Мой заголовок"))
        XCTAssertTrue(md.contains("> Краткая сводка"))     // markdown blockquote summary
        XCTAssertTrue(md.contains("один, два"))            // keywords joined
        XCTAssertTrue(md.contains("- [ ] Позвонить"))      // GFM checkbox (open)
        XCTAssertTrue(md.contains("- [x] Готово"))         // GFM checkbox (done)
        XCTAssertTrue(md.hasSuffix("body text\n"))         // body still last
        // Optional-gate: without the flag the output is the pre-P4 shape (no insight values).
        let off = exportMarkdown(it, content: .transcript)
        XCTAssertFalse(off.contains("Краткая сводка"))
        XCTAssertFalse(off.contains("- [ ]"))
        XCTAssertTrue(off.hasPrefix("## talk.ogg\n"))
        XCTAssertTrue(off.hasSuffix("\n\nbody text\n"))
    }

    func testExportPlainTXTIncludesInsights() {
        var it = makeItem(text: "body text", lang: "ru")
        it.title = "Заголовок"; it.summary = "Сводка"; it.actions = [ActionItem(text: "Готово", done: true)]
        let txt = exportPlainTXT(it, timestamps: false, content: .withInsights)
        XCTAssertTrue(txt.contains("Сводка"))
        XCTAssertTrue(txt.contains("- [x] Готово"))
        XCTAssertTrue(txt.hasSuffix("body text"))   // block precedes the body
        // Optional-gate: false → byte-identical to the plain transcript.
        XCTAssertEqual(exportPlainTXT(it, timestamps: false, content: .transcript), "body text")
    }

    func testExportVTTHasNoteBlock() {
        var v = makeItem(name: "talk.ogg", text: "full", segments: [Segment(start: 0, end: 2, text: "привет")], lang: "ru")
        v.title = "Тайтл"; v.summary = "Сводка"
        let vtt = exportVTT(v, content: .withInsights)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\nNOTE\n"))                      // spec-valid comment block
        XCTAssertTrue(vtt.contains("Сводка"))
        XCTAssertTrue(vtt.contains("00:00:00.000 --> 00:00:02.000\nпривет"))  // cues still parse after the NOTE
        // Optional-gate: false → byte-identical to the plain WebVTT (no NOTE).
        let off = exportVTT(v, content: .transcript)
        XCTAssertFalse(off.contains("NOTE"))
        XCTAssertTrue(off.hasPrefix("WEBVTT\n\n00:00:00.000"))
        XCTAssertEqual(off, exportVTT(v))   // default is false
    }

    func testExportSRTNeverCarriesInsights() {
        var s = makeItem(text: "full", segments: [Segment(start: 0, end: 1, text: "x")], lang: "ru")
        s.title = "Тайтл"; s.summary = "Сводкатекст"; s.actions = [ActionItem(text: "Задача")]
        // SubRip has no comment syntax → insights are deliberately never injected (a header would break players).
        XCTAssertEqual(exportString(s, as: .srt, content: .withInsights),
                       exportString(s, as: .srt, content: .transcript))
        XCTAssertFalse(exportString(s, as: .srt, content: .withInsights).contains("Сводкатекст"))
    }

    func testExportJSONCarriesInsights() throws {
        var j = makeItem(text: "data", segments: [Segment(start: 0, end: 1, text: "x")], lang: "ru")
        j.title = "Заголовок"; j.summary = "Сводка"; j.keywords = ["к1", "к2"]
        j.actions = [ActionItem(text: "Задача", done: true)]
        let back = try JSONDecoder().decode(TranscriptItem.self, from: exportJSON(j))
        XCTAssertEqual(back.title, "Заголовок")          // JSON = the full record → insights ride along
        XCTAssertEqual(back.summary, "Сводка")
        XCTAssertEqual(back.keywords, ["к1", "к2"])
        XCTAssertEqual(back.actions?.map(\.text), ["Задача"])
        XCTAssertEqual(back.actions?.first?.done, true)
        XCTAssertEqual(back, j)                           // full round-trip (no drift)
    }

    /// A long note with per-chapter summaries exports a chapter digest ABOVE the full transcript (chapters ADD,
    /// never replace). Gated by the content mode; absent for short / summary-less notes.
    func testExportLongNoteHasChapterDigest() {
        var it = makeItem(name: "talk.ogg", text: "полный текст записи", segments: [
            Segment(start: 0, end: 5, text: "первая"),
            Segment(start: 130, end: 135, text: "вторая"),
        ], lang: "ru")
        it.durationSec = 700
        it.chapterSummaries = [ChapterSummary(startSec: 0, endSec: 120, summary: "сум один"),
                               ChapterSummary(startSec: 120, endSec: 240, summary: "сум два")]
        let md = exportMarkdown(it, content: .withInsights)
        XCTAssertTrue(md.contains("### [00:00"))               // chapter heading (range label)
        XCTAssertTrue(md.contains("> сум один"))
        XCTAssertTrue(md.contains("> сум два"))
        XCTAssertTrue(md.contains("полный текст записи"))      // full transcript still present (ADD, not replace)
        XCTAssertFalse(exportMarkdown(it, content: .transcript).contains("### ["))   // gated by the flag
        // A note without chapter summaries → no chapter sections even with the flag.
        let bare = makeItem(text: "коротыш", lang: "ru")
        XCTAssertFalse(exportMarkdown(bare, content: .withInsights).contains("### ["))
    }

    /// "Summary only" export (P4 punch-list 7): emits the insight header (and chapter digest) WITHOUT the
    /// transcript body. ".withInsights" keeps both.
    func testExportInsightsOnlyDropsBody() {
        var it = makeItem(name: "talk.ogg", text: "полный текст записи здесь", lang: "ru")
        it.summary = "Сводка тут"; it.keywords = ["к1"]
        let md = exportMarkdown(it, content: .insightsOnly)
        XCTAssertTrue(md.contains("Сводка тут"))
        XCTAssertFalse(md.contains("полный текст записи здесь"))   // body dropped
        let txt = exportPlainTXT(it, timestamps: false, content: .insightsOnly)
        XCTAssertTrue(txt.contains("Сводка тут"))
        XCTAssertFalse(txt.contains("полный текст записи здесь"))
        XCTAssertTrue(exportMarkdown(it, content: .withInsights).contains("полный текст записи здесь"))   // both kept
    }

    func testExportFormatSupportsInsightsOnly() {
        XCTAssertTrue(ExportFormat.txt.supportsInsightsOnly)
        XCTAssertTrue(ExportFormat.markdown.supportsInsightsOnly)
        XCTAssertFalse(ExportFormat.srt.supportsInsightsOnly)     // subtitles need the body
        XCTAssertFalse(ExportFormat.vtt.supportsInsightsOnly)
        XCTAssertFalse(ExportFormat.json.supportsInsightsOnly)    // JSON = full record
    }

    /// Truncated summaries (token-cap cutoff) are trimmed back to the last complete sentence — never a dangling word.
    func testCompleteSentences() {
        XCTAssertEqual(completeSentences("Привет. Как дел"), "Привет.")              // drop the dangling fragment
        XCTAssertEqual(completeSentences("Готово."), "Готово.")                      // already clean → unchanged
        XCTAssertEqual(completeSentences("Раз. Два! Три? Четыре"), "Раз. Два! Три?") // trim to the last terminal
        XCTAssertEqual(completeSentences("Хвост…"), "Хвост…")                        // ellipsis is a clean end
        XCTAssertEqual(completeSentences("без точек вообще"), "без точек вообще")    // no boundary → leave as-is
        XCTAssertEqual(completeSentences("Он сказал «да»."), "Он сказал «да».")      // closer after terminal → clean
        XCTAssertEqual(completeSentences("  пробелы.  "), "пробелы.")                // trims surrounding whitespace
    }

    func testExportEditedRecordDegrades() {
        // text ≠ segments → one full-text cue [0, durationSec=1], never the stale segment timecodes
        let item = makeItem(text: "edited full text",
                            segments: [Segment(start: 0, end: 1, text: "stale"),
                                       Segment(start: 1, end: 2, text: "old")],
                            edited: true)
        XCTAssertEqual(exportSRT(item), "1\n00:00:00,000 --> 00:00:01,000\nedited full text\n\n")
        XCTAssertTrue(exportVTT(item).contains("00:00:00.000 --> 00:00:01.000\nedited full text\n"))
        XCTAssertFalse(exportSRT(item).contains("stale"))
    }

    func testExportEmptySegments() {
        // no segments, not edited → degrade to one full-text cue [0, duration]
        let item = makeItem(text: "только текст", segments: [])
        XCTAssertEqual(exportSRT(item), "1\n00:00:00,000 --> 00:00:01,000\nтолько текст\n\n")
        // truly empty (no text either) → empty SRT, valid-but-empty VTT — never 0-cue garbage
        let blank = makeItem(text: "", segments: [])
        XCTAssertEqual(exportSRT(blank), "")
        XCTAssertEqual(exportVTT(blank), "WEBVTT\n\n")
    }

    func testExportFormatMetadata() {
        XCTAssertEqual(ExportFormat.allCases.count, 5)
        let exts = ExportFormat.allCases.map(\.fileExtension)
        XCTAssertEqual(Set(exts).count, exts.count)    // unique extensions
        XCTAssertEqual(ExportFormat.srt.fileExtension, "srt")
        XCTAssertEqual(ExportFormat.markdown.fileExtension, "md")
        XCTAssertTrue(ExportFormat.json.supportsWholeHistory)
        XCTAssertFalse(ExportFormat.srt.supportsWholeHistory)
        XCTAssertFalse(ExportFormat.vtt.supportsWholeHistory)
        XCTAssertTrue(ExportFormat.allCases.allSatisfy { !$0.displayName.isEmpty })
    }

    func testSRTClampsEndBeforeStart() {
        let item = makeItem(text: "x", segments: [Segment(start: 5, end: 2, text: "reversed")])
        // end clamped to start → never a reversed `-->` range
        XCTAssertEqual(exportSRT(item), "1\n00:00:05,000 --> 00:00:05,000\nreversed\n\n")
    }


    // MARK: WhisperKit token cleanup (transcript display correctness)

    func testStripWhisperTokens() {
        XCTAssertEqual(stripWhisperTokens("<|startoftranscript|><|ru|><|transcribe|><|0.00|> привет мир<|8.52|>"), "привет мир")
        XCTAssertEqual(stripWhisperTokens("чисто без токенов"), "чисто без токенов")   // no-op on clean text
        XCTAssertEqual(stripWhisperTokens("<|endoftext|>"), "")                          // tokens-only → empty
        XCTAssertEqual(stripWhisperTokens("a<|1.0|>  b"), "a b")                         // collapses doubled spaces
        XCTAssertEqual(stripWhisperTokens("  <|x|> trim "), "trim")
    }

    func testSegmentCleanText() {
        XCTAssertEqual(Segment(start: 0, end: 1, text: "<|0.00|> привет<|8.52|>").cleanText, "привет")
        XCTAssertEqual(Segment(start: 0, end: 1, text: "чисто").cleanText, "чисто")
    }

    func testDisplayStripsWhisperTokens() {
        let item = makeItem(text: "привет мир", segments: [
            Segment(start: 0, end: 1, text: "<|0.00|> привет<|1.0|>"),
            Segment(start: 1, end: 2, text: "<|1.0|> мир<|2.0|>"),
        ])
        XCTAssertEqual(item.display(timestamps: true), "[00:00] привет\n[00:01] мир")
    }

    func testExportStripsWhisperTokens() {
        let item = makeItem(text: "full", segments: [
            Segment(start: 0, end: 2, text: "<|startoftranscript|><|0.00|> hello<|2.0|>"),
        ])
        XCTAssertEqual(exportSRT(item), "1\n00:00:00,000 --> 00:00:02,000\nhello\n\n")
        XCTAssertTrue(exportVTT(item).contains("hello"))
        XCTAssertFalse(exportVTT(item).contains("startoftranscript"))
    }


}
