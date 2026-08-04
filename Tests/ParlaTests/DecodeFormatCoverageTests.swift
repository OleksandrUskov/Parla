import XCTest
import AVFoundation
@testable import ParlaCore

/// Two formats were dropped when decoding moved in-process, and neither had to be.
///
/// Both fixtures are synthesised tones committed to the repo — no voice, a few KB each — so these run on every
/// machine and in CI rather than depending on something a developer happens to have locally.
final class DecodeFormatCoverageTests: XCTestCase {

    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"),
                      "missing fixture \(name).\(ext) — check Package.swift resources")
    }

    /// THE regression: `looksLikeOgg` routes every `OggS` file to libopusfile, which decodes Ogg-**Opus** only.
    /// An Ogg-Vorbis file is also `.ogg`, so it failed outright — while AVFoundation reads it perfectly well
    /// (measured: 1 track, 3.13 s). That was a silent format loss against the previous build, and the cure is one
    /// retry on the second lane.
    func testOggVorbisFallsBackToTheSecondLane() throws {
        let src = try fixture("vorbis", "ogg")
        XCTAssertTrue(OpusAudioDecoder.looksLikeOgg(src), "precondition: it IS an Ogg container, so lane 1 runs first")

        let wav = try OpusAudioDecoder().decodeToWav16k(src)
        defer { try? FileManager.default.removeItem(at: wav) }
        let file = try AVAudioFile(forReading: wav)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertGreaterThan(Double(file.length) / file.fileFormat.sampleRate, 2,
                             "the fixture is 3 s — a fallback that produced nothing would be worse than the bug")
    }

    /// The long-audio path must not be lost for the same reason, so the fallback lives in chunking too.
    func testOggVorbisChunksThroughTheFallbackToo() throws {
        let src = try fixture("vorbis", "ogg")
        let chunks = try OpusAudioDecoder().splitIntoChunks(src, chunkLength: 1.0)
        defer { chunks.first.map { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }
        XCTAssertGreaterThanOrEqual(chunks.count, 2, "3 s split at 1 s should yield several chunks")
        XCTAssertEqual(chunks, chunks.sorted { $0.lastPathComponent < $1.lastPathComponent }, "chunks stay ordered")
    }

    /// `amr` was dropped on the assumption that AVFoundation had no AMR decoder. It does — and `.3gp`, the same
    /// codec family, was kept anyway, so the drop was self-inconsistent as well as wrong.
    func testAmrDecodes() throws {
        let src = try fixture("tone", "amr")
        let wav = try OpusAudioDecoder().decodeToWav16k(src)
        defer { try? FileManager.default.removeItem(at: wav) }
        XCTAssertGreaterThan(Double(try AVAudioFile(forReading: wav).length), 0)
    }

    /// Decoding it is useless if the app refuses to accept the file in the first place.
    func testAmrIsAcceptedByIntake() throws {
        XCTAssertTrue(AppModel.audioExts.contains("amr"), "advertised as importable")
        let named = FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID().uuidString).amr")
        try Data("x".utf8).write(to: named)
        defer { try? FileManager.default.removeItem(at: named) }
        XCTAssertTrue(AppModel.isTranscribable(named))
    }

    /// amr must NOT join `avDecodable`: that list means "hand straight to the engine, no decode", and this one
    /// needs Lane 2. The subset invariant is what keeps a wrong entry from hard-failing instead of routing.
    func testAmrRoutesThroughTheDecoderRatherThanStraightToTheEngine() {
        XCTAssertFalse(AppModel.avDecodable.contains("amr"))
        XCTAssertTrue(AppModel.avDecodable.isSubset(of: AppModel.audioExts))
    }

    /// A cancel must not be mistaken for "this lane can't read it" and quietly retried on the next one — that
    /// would ignore exactly what the user asked for.
    func testCancellationIsNotSwallowedByTheFallback() throws {
        let src = try fixture("vorbis", "ogg")
        let control = DecodeControl()
        control.cancel()
        XCTAssertThrowsError(try OpusAudioDecoder().decodeToWav16k(src, control: control)) { error in
            XCTAssertEqual(error as? AudioDecodingError, .cancelled,
                           "a cancelled decode must report the cancel, not fall through to another lane")
        }
    }
}
