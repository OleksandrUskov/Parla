import XCTest
import AVFoundation
import CoreMedia
import ParlaCore

// Lane-2 (`AVAssetReader`) decode proof. Exercises the SECOND decode lane of the iOS
// `AudioDecoding` seam: a non-Ogg/Opus container (here an AAC `.mp4`) → a 16 kHz mono WAV the engine can read.
//
// Fixture-free + committable: the source is SYNTHESIZED in-process (AVAssetWriter encodes a short 440 Hz sine to
// AAC/mp4), so this needs no gitignored voice fixture and runs green in CI on the simulator. It proves the real
// integration risks of Lane-2 — the reader opens/demuxes the container, resamples 44.1 kHz → 16 kHz, downmixes
// to mono, and the streaming CMSampleBuffer → AVAudioFile copy produces a valid WAV of the expected length.
final class AVAssetDecodeTests: XCTestCase {

    func testLane2DecodesAacMp4To16kMonoWav() throws {
        let seconds = 2.0
        let srcSampleRate = 44_100.0
        let src = try makeSineMP4(seconds: seconds, sampleRate: srcSampleRate)
        defer { try? FileManager.default.removeItem(at: src) }

        // Route through the PUBLIC seam — `.mp4` is not in `avDecodable`, so it dispatches to Lane-2.
        let wav = try OpusAudioDecoder().decodeToWav16k(src)
        defer { try? FileManager.default.removeItem(at: wav) }

        let out = try AVAudioFile(forReading: wav)
        XCTAssertEqual(out.fileFormat.sampleRate, 16_000, "Lane-2 must resample to 16 kHz")
        XCTAssertEqual(out.fileFormat.channelCount, 1, "Lane-2 must downmix to mono")
        // AAC priming/padding shifts the exact frame count a little → assert it's within ~150 ms of 2 s @ 16 kHz.
        let expected = seconds * 16_000
        XCTAssertEqual(Double(out.length), expected, accuracy: 2_400,
                       "decoded length \(out.length) should be ~\(Int(expected)) frames")
    }

    func testLane2ChunkingCutsExactBoundaries() throws {
        let seconds = 5.0
        let chunkLength = 2.0
        let framesPerChunk = 32_000            // 2 s @ 16 kHz
        let src = try makeSineMP4(seconds: seconds, sampleRate: 44_100)
        defer { try? FileManager.default.removeItem(at: src) }

        let chunks = try OpusAudioDecoder().splitIntoChunks(src, chunkLength: chunkLength)
        defer { chunks.first.map { try? FileManager.default.removeItem(at: $0.deletingLastPathComponent()) } }

        // ceil(5 s / 2 s) = 3 chunks; exact cutting → the first two are precisely one chunk long.
        XCTAssertEqual(chunks.count, 3, "5 s split at 2 s should yield 3 chunks")
        XCTAssertEqual(chunks, chunks.sorted { $0.lastPathComponent < $1.lastPathComponent }, "chunks must be ordered")
        XCTAssertEqual(Set(chunks.map { $0.deletingLastPathComponent() }).count, 1, "all chunks under one temp dir")

        var totalFrames: AVAudioFramePosition = 0
        for (i, chunk) in chunks.enumerated() {
            let f = try AVAudioFile(forReading: chunk)
            XCTAssertEqual(f.fileFormat.sampleRate, 16_000)
            XCTAssertEqual(f.fileFormat.channelCount, 1)
            if i < 2 { XCTAssertEqual(f.length, AVAudioFramePosition(framesPerChunk), "chunk \(i) must be an exact boundary cut") }
            totalFrames += f.length
        }
        // No frames dropped across the split (within AAC priming/padding slack).
        XCTAssertEqual(Double(totalFrames), seconds * 16_000, accuracy: 2_400)
    }

    // MARK: - Synthetic AAC/mp4 source (no fixture on disk)

    /// Encode `seconds` of a 440 Hz sine (mono, `sampleRate`) to an AAC `.mp4` via `AVAssetWriter`. Returns the
    /// temp file URL (caller removes it). Software AAC encoding is available on the iOS simulator.
    private func makeSineMP4(seconds: Double, sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parla-src-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ])
        input.expectsMediaDataInRealTime = false
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "writer failed to start: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(seconds * sampleRate)
        let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                      channels: 1, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(frameCount))!
        pcm.frameLength = AVAudioFrameCount(frameCount)
        let ch = pcm.floatChannelData![0]
        for i in 0 ..< frameCount { ch[i] = sinf(2 * .pi * 440 * Float(i) / Float(sampleRate)) * 0.2 }

        let sampleBuffer = try Self.sampleBuffer(from: pcm)
        while !input.isReadyForMoreMediaData { usleep(1_000) }
        XCTAssertTrue(input.append(sampleBuffer), "AAC append failed")
        input.markAsFinished()

        // 120 s, not 15: this synthesises AAC through the SOFTWARE encoder, and on a loaded CI simulator that can
        // take far longer than on a developer's Mac. The old 15 s passed locally for months and then failed on the
        // runner the first time CI actually executed this suite — a slow machine, not a broken encoder.
        let done = XCTestExpectation(description: "writer finished")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 120)
        XCTAssertEqual(writer.status, .completed, "AAC writer did not finish: status=\(writer.status.rawValue) error=\(String(describing: writer.error))")
        return url
    }

    /// Wrap a PCM `AVAudioPCMBuffer` into a `CMSampleBuffer` an `AVAssetWriterInput` can append.
    private static func sampleBuffer(from pcm: AVAudioPCMBuffer) throws -> CMSampleBuffer {
        var formatDesc: CMAudioFormatDescription?
        var asbd = pcm.format.streamDescription.pointee
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &formatDesc)
        var sampleBuffer: CMSampleBuffer?
        let timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                             makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDesc,
                             sampleCount: CMItemCount(pcm.frameLength), sampleTimingEntryCount: 1,
                             sampleTimingArray: [timing], sampleSizeEntryCount: 0, sampleSizeArray: nil,
                             sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { throw AudioDecodingError.noDecoderAvailable }
        CMSampleBufferSetDataBufferFromAudioBufferList(sampleBuffer, blockBufferAllocator: kCFAllocatorDefault,
                                                       blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                       flags: 0, bufferList: pcm.mutableAudioBufferList)
        return sampleBuffer
    }
}
