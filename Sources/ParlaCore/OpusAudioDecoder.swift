#if os(iOS)
import Foundation
import AVFoundation
import CoreMedia
import opus

/// iOS in-process `AudioDecoding` (iOS-port P1.3). The macOS ffmpeg subprocess is impossible on iOS, so the
/// transcription pipeline's decode seam is served here by two pure-library lanes that both stream one small
/// mono Float32 buffer at a time (bounded memory regardless of length):
///
/// - **LANE-1 — Ogg/Opus (`libopusfile`):** Telegram `.ogg`/`.opus` → 48 kHz mono. AVFoundation can't demux
///   Ogg/Opus, hence the dedicated Opusfile path.
/// - **LANE-2 — everything else AVFoundation can demux (`AVAssetReader`):** mp4/mov/m4v/flac/… → 16 kHz mono
///   (the reader resamples + downmixes for us). Throws when the source has no readable audio track.
///
/// AV-native containers (m4a/mp3/wav/aac/caf/aiff — `AppModel.avDecodable`) never reach this seam; WhisperKit
/// opens them directly. Each lane's WAV is Float32 at its native rate; WhisperKit resamples to 16 kHz on load.
///
/// `splitIntoChunks` streams either lane into `ChunkWriter`, which cuts EXACTLY on `chunkLength`-second
/// boundaries so the pipeline's nominal per-chunk timeline offsets (`AudioChunker.stitch`, `k * chunkLength`)
/// stay accurate with no compounding drift. webm is scoped OUT of iOS v1 (§2 — no clean in-process decoder).
public struct OpusAudioDecoder: AudioDecoding {
    public init() {}

    private static let opusExtensions: Set<String> = ["ogg", "oga", "opus"]
    private static let opusSampleRate = 48_000.0    // Opusfile decodes at the Opus-native rate
    private static let avAssetSampleRate = 16_000.0 // AVAssetReader resamples to the engine's rate for us

    // MARK: - AudioDecoding

    public func decodeToWav16k(_ src: URL) throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("parla-decode-\(UUID().uuidString).wav")
        try Self.writeMonoWav(from: src, to: dest)
        return dest
    }

    /// Split a long source into ~`chunkLength`-second 16 kHz/48 kHz mono WAV chunks under one temp dir (the
    /// caller removes it, deriving it from the first chunk URL). An empty result → the caller falls back to a
    /// single pass; since it can't derive a dir from zero chunks, this cleans its own temp dir in that case.
    public func splitIntoChunks(_ src: URL, chunkLength: Double) throws -> [URL] {
        let lane = try Self.lane(for: src)
        guard let format = Self.monoFloatFormat(sampleRate: lane.sampleRate) else {
            throw AudioDecodingError.noDecoderAvailable
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parla-chunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let framesPerChunk = AVAudioFrameCount(max(1, chunkLength * lane.sampleRate))
        let writer = ChunkWriter(dir: dir, format: format, framesPerChunk: framesPerChunk)
        do {
            try lane.read(src, format) { try writer.append($0) }
            writer.close()
        } catch {
            try? FileManager.default.removeItem(at: dir)    // failed split → don't leak the temp chunk dir
            throw error
        }
        let urls = writer.urls
        if urls.isEmpty { try? FileManager.default.removeItem(at: dir) }
        return urls
    }

    public var isChunkingAvailable: Bool { true }

    /// In-app playback rendition for iOS. Reuses the same decode lanes that feed WhisperKit to write a mono
    /// Float32 WAV the built-in `AVAudioPlayer` can open — so an imported Telegram Ogg/Opus (or video, whose
    /// original container AVAudioPlayer can't open) is PLAYABLE on iOS, matching macOS where FFmpegAudioDecoder
    /// renders a playable .m4a. `renderPlayableM4a` stays unimplemented on purpose: `AudioStore.makePlayable`
    /// tries M4a first, then falls back to this WAV (larger, but the audio cache is capped/managed). webm is
    /// scoped out of iOS v1 either way (no in-process decoder → both renditions throw → no player, by design).
    public func renderPlayableM4a(from src: URL, to dest: URL) throws { throw AudioDecodingError.noDecoderAvailable }
    public func renderPlayableWav(from src: URL, to dest: URL) throws { try Self.writeMonoWav(from: src, to: dest) }

    // MARK: - Lane selection

    /// A lane streams mono Float32 buffers (at `sampleRate`) from `src` into a `sink`, one small buffer at a time.
    private typealias FrameReader = (_ src: URL, _ format: AVAudioFormat,
                                     _ sink: (AVAudioPCMBuffer) throws -> Void) throws -> Void

    private static func lane(for src: URL) throws -> (read: FrameReader, sampleRate: Double) {
        if opusExtensions.contains(src.pathExtension.lowercased()) {
            return (readOpusFrames, opusSampleRate)
        }
        return (readAVAssetFrames, avAssetSampleRate)
    }

    private static func monoFloatFormat(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    }

    /// Decode `src` (either lane) → a mono Float32 WAV at `dest` that AVAudioFile/AVAudioPlayer can open. Shared by
    /// `decodeToWav16k` (temp dest → engine input) and `renderPlayableWav` (cache dest → in-app player). Cleans up a
    /// partial or 0-frame WAV so a failed/empty decode can't masquerade as a valid (silent) file downstream.
    private static func writeMonoWav(from src: URL, to dest: URL) throws {
        let lane = try lane(for: src)
        guard let format = monoFloatFormat(sampleRate: lane.sampleRate) else {
            throw AudioDecodingError.noDecoderAvailable
        }
        let out = try AVAudioFile(forWriting: dest, settings: format.settings)
        do {
            try lane.read(src, format) { try out.write(from: $0) }
        } catch {
            try? FileManager.default.removeItem(at: dest)   // drop a partial WAV so it can't masquerade as decoded
            throw error
        }
        guard out.length > 0 else {
            try? FileManager.default.removeItem(at: dest)
            throw AudioDecodingError.noDecoderAvailable
        }
    }

    // MARK: - Lane 1 read loop — Ogg/Opus (libopusfile), 48 kHz

    /// `op_open_file` reads the container incrementally from disk; each `op_read_float` page is downmixed to
    /// mono and handed to `sink`. O(one page) memory regardless of length. The single reused `mono` buffer is
    /// safe because `sink` consumes it synchronously (AVAudioFile.write / ChunkWriter copy on write).
    private static func readOpusFrames(_ src: URL, _ format: AVAudioFormat,
                                       _ sink: (AVAudioPCMBuffer) throws -> Void) throws {
        var err: Int32 = 0
        guard let file = op_open_file(src.path, &err), err == 0 else { throw AudioDecodingError.noDecoderAvailable }
        defer { op_free(file) }

        let firstChannels = Int(op_channel_count(file, -1))
        guard firstChannels > 0 else { throw AudioDecodingError.noDecoderAvailable }

        // `op_read_float` never writes past the buffer size we pass, so a fixed buffer is overflow-safe for ANY
        // link's channel count. Size it (and the mono buffer) for the first link's count: that also covers the
        // worst case where a later CHAINED link has fewer channels (a mono link yields up to `capacity` frames,
        // which the mono buffer must be able to hold). Telegram voice is single-link mono → capacity == 5760.
        let capacity = 5760 * firstChannels                                // Opusfile yields ≤ 5760 frames/channel per call
        guard let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)) else {
            throw AudioDecodingError.noDecoderAvailable
        }
        var interleaved = [Float](repeating: 0, count: capacity)

        while true {
            var li: Int32 = -1
            let n = interleaved.withUnsafeMutableBufferPointer {
                op_read_float(file, $0.baseAddress, Int32($0.count), &li)   // frames PER CHANNEL; fills `li` (the link)
            }
            if n == OP_HOLE { continue }                                   // recoverable gap (corrupt/missing page) → keep going
            if n < 0 { throw AudioDecodingError.noDecoderAvailable }        // genuine error (OP_EREAD/OP_EBADPACKET/…)
            if n == 0 { break }                                            // EOF

            // Re-read THIS link's channel count — a chained stream can change it link-to-link, and a stale count
            // would mis-stride the downmix (garble) or, for stereo→mono, overrun the mono buffer.
            let channels = max(1, Int(op_channel_count(file, li)))
            let frames = Int(n)
            let dst = mono.floatChannelData![0]
            if channels == 1 {
                interleaved.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: frames) }
            } else {
                for f in 0 ..< frames {                                     // downmix to mono
                    var acc: Float = 0
                    for c in 0 ..< channels { acc += interleaved[f * channels + c] }
                    dst[f] = acc / Float(channels)
                }
            }
            mono.frameLength = AVAudioFrameCount(frames)
            try sink(mono)
        }
    }

    // MARK: - Lane 2 read loop — AVAssetReader (mp4/mov/m4v/flac/…), 16 kHz

    /// Output PCM spec for `AVAssetReaderTrackOutput`: the reader resamples to 16 kHz and downmixes to mono,
    /// delivering interleaved Float32 (mono → interleaved == non-interleaved). Computed (not a stored `static
    /// let`) so the `[String: Any]` isn't a non-Sendable global under `.v6`.
    private static var pcm16kMonoSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: avAssetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Drain the first audio track one `CMSampleBuffer` at a time into `sink`. The synchronous
    /// `tracks(withMediaType:)` is intentional: this seam is `throws`-sync and always runs off the main actor
    /// (`Task.detached` in the pipeline), so the brief synchronous property load is fine.
    private static func readAVAssetFrames(_ src: URL, _ format: AVAudioFormat,
                                          _ sink: (AVAudioPCMBuffer) throws -> Void) throws {
        let asset = AVURLAsset(url: src)
        let audioTracks = asset.tracks(withMediaType: .audio)
        // Prefer an ENABLED audio track over raw track order: multi-audio-track containers (screen recordings =
        // mic + system audio, multi-language m4v) can list a non-default track first, and `.first` would
        // silently transcribe the wrong/silent one. Falls back to the first track when none flags enabled.
        guard let track = audioTracks.first(where: { $0.isEnabled }) ?? audioTracks.first else {
            throw AudioDecodingError.noDecoderAvailable   // no audio stream / unreadable container
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcm16kMonoSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioDecodingError.noDecoderAvailable }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AudioDecodingError.noDecoderAvailable }

        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sample) }   // drop the backing store promptly (streaming)
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let byteCount = CMBlockBufferGetDataLength(block)
            let frames = byteCount / MemoryLayout<Float>.stride
            guard frames > 0,
                  let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
            else { continue }
            buf.frameLength = AVAudioFrameCount(frames)
            let status = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount,
                                                    destination: buf.floatChannelData![0])
            guard status == kCMBlockBufferNoErr else { continue }
            try sink(buf)
        }
        if reader.status == .failed { throw reader.error ?? AudioDecodingError.noDecoderAvailable }
    }
}

/// Streams mono Float32 buffers into a sequence of `chunk_%04d.wav` files, cutting EXACTLY on `framesPerChunk`
/// boundaries (a buffer that straddles a boundary is split) so every chunk but the last is exactly
/// `chunkLength` seconds — keeping `AudioChunker`'s nominal `k * chunkLength` offsets drift-free. Only one
/// `AVAudioFile` is open at a time → bounded memory. Used synchronously within one `splitIntoChunks` call
/// (never shared across threads), so it needs no locking.
private final class ChunkWriter {
    private let dir: URL
    private let format: AVAudioFormat
    private let framesPerChunk: AVAudioFrameCount
    private var current: AVAudioFile?
    private var framesInCurrent: AVAudioFrameCount = 0
    private var index = 0
    private(set) var urls: [URL] = []

    init(dir: URL, format: AVAudioFormat, framesPerChunk: AVAudioFrameCount) {
        self.dir = dir
        self.format = format
        self.framesPerChunk = framesPerChunk
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        let total = buffer.frameLength
        guard total > 0 else { return }
        if current == nil { try rollover() }

        // Fast path: the whole buffer fits in the current chunk → write as-is (no copy).
        if framesInCurrent + total <= framesPerChunk {
            try current!.write(from: buffer)
            framesInCurrent += total
            return
        }

        // Straddles ≥ 1 boundary → copy out exact slices, rolling over on each full chunk.
        let src = buffer.floatChannelData![0]
        var offset: AVAudioFrameCount = 0
        while offset < total {
            if framesInCurrent >= framesPerChunk { try rollover() }
            let take = min(framesPerChunk - framesInCurrent, total - offset)
            guard let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: take) else {
                throw AudioDecodingError.noDecoderAvailable
            }
            slice.frameLength = take
            slice.floatChannelData![0].update(from: src + Int(offset), count: Int(take))
            try current!.write(from: slice)
            offset += take
            framesInCurrent += take
        }
    }

    /// Release the open file so its buffered frames flush to disk (AVAudioFile writes eagerly, but dropping the
    /// reference is the clean end-of-stream). Chunk URLs are already recorded in `urls`.
    func close() { current = nil }

    private func rollover() throws {
        let url = dir.appendingPathComponent(String(format: "chunk_%04d.wav", index))
        current = try AVAudioFile(forWriting: url, settings: format.settings)
        urls.append(url)
        framesInCurrent = 0
        index += 1
    }
}
#endif
