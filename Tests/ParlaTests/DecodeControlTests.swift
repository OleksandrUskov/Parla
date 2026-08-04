import XCTest
import AVFoundation
@testable import ParlaCore

/// The decode loops had no way out: they ran in a detached task (which does not inherit cancellation) and
/// checked nothing, so the Cancel button was a lie for the whole decode phase — on a long file, minutes of a
/// button that does nothing. The old ffmpeg subprocess had a 1800 s watchdog; nothing replaced it when decoding
/// moved in-process, so a wedged read had nothing to stop it either.
final class DecodeControlTests: XCTestCase {

    func testCancelIsObservedByTheNextCheck() throws {
        let control = DecodeControl()
        XCTAssertNoThrow(try control.check(), "a fresh control must not throw")
        XCTAssertFalse(control.isCancelled)

        control.cancel()
        XCTAssertTrue(control.isCancelled)
        XCTAssertThrowsError(try control.check()) { error in
            XCTAssertEqual(error as? AudioDecodingError, .cancelled)
        }
    }

    func testCancelIsIdempotentAndSticky() {
        let control = DecodeControl()
        control.cancel(); control.cancel()
        XCTAssertTrue(control.isCancelled, "cancellation never un-cancels")
        XCTAssertThrowsError(try control.check())
    }

    /// The watchdog. A deadline already in the past is the cheap stand-in for a wedged read.
    func testAnExpiredDeadlineThrowsTimedOutNotCancelled() {
        let control = DecodeControl(timeout: -1)
        XCTAssertThrowsError(try control.check()) { error in
            XCTAssertEqual(error as? AudioDecodingError, .timedOut,
                           "a wedge must be distinguishable from a user cancel — they mean different things to the user")
        }
    }

    func testAGenerousDeadlineDoesNotFireDuringNormalWork() throws {
        let control = DecodeControl(timeout: 1800)
        for _ in 0..<1000 { try control.check() }
    }

    /// `timeout: nil` means "no watchdog" — used where a caller wants only user-cancellation.
    func testNilTimeoutMeansNoDeadline() throws {
        let control = DecodeControl(timeout: nil)
        try control.check()
        control.cancel()
        XCTAssertThrowsError(try control.check()) { XCTAssertEqual($0 as? AudioDecodingError, .cancelled) }
    }

    /// Cancellation crosses threads: the flag is set on the main actor (the button) and read wherever the decode
    /// happens to run. This would trip ThreadSanitizer if the lock were missing.
    func testCancelFromAnotherThreadIsSeen() {
        let control = DecodeControl()
        let done = expectation(description: "cancelled off-thread")
        DispatchQueue.global().async { control.cancel(); done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertThrowsError(try control.check())
    }

    // MARK: - The real decoder honours it

    /// REPRO-GATE: cancel before the decode starts and the real decoder must refuse to produce a file. Before
    /// this existed the decode ran to completion regardless — which is precisely the bug.
    func testRealDecoderStopsWhenCancelledAndLeavesNoPartialFile() throws {
        let src = try makeSineWav(seconds: 3)
        defer { try? FileManager.default.removeItem(at: src) }

        let control = DecodeControl()
        control.cancel()
        var produced: URL?
        XCTAssertThrowsError(try { produced = try OpusAudioDecoder().decodeToWav16k(src, control: control) }()) { error in
            XCTAssertEqual(error as? AudioDecodingError, .cancelled)
        }
        if let produced {
            XCTAssertFalse(FileManager.default.fileExists(atPath: produced.path),
                           "a cancelled decode must not leave a partial WAV that looks decoded")
            try? FileManager.default.removeItem(at: produced)
        }
    }

    /// The watchdog reaches the real decoder too, and reports the wedge as a timeout rather than a cancel.
    func testRealDecoderHonoursTheDeadline() throws {
        let src = try makeSineWav(seconds: 3)
        defer { try? FileManager.default.removeItem(at: src) }
        XCTAssertThrowsError(try OpusAudioDecoder().decodeToWav16k(src, control: DecodeControl(timeout: -1))) { error in
            XCTAssertEqual(error as? AudioDecodingError, .timedOut)
        }
    }

    /// Without a control the decoder behaves exactly as before — the seam's default keeps every existing call
    /// site and test double untouched.
    func testNoControlMeansUnchangedBehaviour() throws {
        let src = try makeSineWav(seconds: 1)
        defer { try? FileManager.default.removeItem(at: src) }
        let out = try OpusAudioDecoder().decodeToWav16k(src)
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertGreaterThan(try AVAudioFile(forReading: out).length, 0)
    }

    /// The hole guard is bounded by a constant rather than by luck: an unbounded `OP_HOLE` retry meant one
    /// damaged Ogg could spin until the user force-quit the app.
    func testHoleGuardIsBounded() {
        XCTAssertGreaterThan(OpusAudioDecoder.maxConsecutiveHoles, 0)
        XCTAssertLessThan(OpusAudioDecoder.maxConsecutiveHoles, 10_000, "a 'bound' that large is not a bound")
    }

    // MARK: -

    private func makeSineWav(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("decodectl-\(UUID().uuidString).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = Int(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buffer.floatChannelData![0][i] = sinf(Float(i) * 0.01) * 0.25 }
        try file.write(from: buffer)
        return url
    }
}
