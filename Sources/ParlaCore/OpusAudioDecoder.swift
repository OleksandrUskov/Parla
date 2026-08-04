#if os(iOS) || os(macOS)
import Foundation
import AVFoundation
import CoreMedia
import opus

/// In-process `AudioDecoding` for iOS and the macOS Mac-App-Store build (Phase 2c native-first — replaces the
/// vendored ffmpeg subprocess in the main decode path). The transcription pipeline's decode seam is served here
/// by two pure-library lanes that both stream one small mono Float32 buffer at a time (bounded memory regardless
/// of length):
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
/// stay accurate with no compounding drift. webm is scoped OUT of iOS v1 (no clean in-process decoder).
public struct OpusAudioDecoder: AudioDecoding {
    public init() {}

    private static let opusExtensions: Set<String> = ["ogg", "oga", "opus"]
    /// How many gap-only reads in a row still count as "a damaged but readable file" rather than a wedge.
    /// 512 x up to 5760 frames is well over a minute of pure gaps — far past anything a real recording produces.
    static let maxConsecutiveHoles = 512

    private static let opusSampleRate = 48_000.0    // Opusfile decodes at the Opus-native rate
    private static let avAssetSampleRate = 16_000.0 // AVAssetReader resamples to the engine's rate for us

    // MARK: - AudioDecoding

    public func decodeToWav16k(_ src: URL) throws -> URL { try decodeToWav16k(src, control: nil) }

    public func decodeToWav16k(_ src: URL, control: DecodeControl?) throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("parla-decode-\(UUID().uuidString).wav")
        try Self.writeMonoWav(from: src, to: dest, control: control)
        return dest
    }

    /// Split a long source into ~`chunkLength`-second 16 kHz/48 kHz mono WAV chunks under one temp dir (the
    /// caller removes it, deriving it from the first chunk URL). An empty result → the caller falls back to a
    /// single pass; since it can't derive a dir from zero chunks, this cleans its own temp dir in that case.
    public func splitIntoChunks(_ src: URL, chunkLength: Double) throws -> [URL] {
        try splitIntoChunks(src, chunkLength: chunkLength, control: nil)
    }

    public func splitIntoChunks(_ src: URL, chunkLength: Double, control: DecodeControl?) throws -> [URL] {
        // Same lane fallback as the single-pass decode: an Ogg-Vorbis file must not lose the long-audio path
        // just because libopusfile can't read it.
        var lastError: Error = AudioDecodingError.unsupportedContainer(src.pathExtension)
        for lane in Self.lanes(for: src) {
            guard let format = Self.monoFloatFormat(sampleRate: lane.sampleRate) else { continue }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("parla-chunks-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let framesPerChunk = AVAudioFrameCount(max(1, chunkLength * lane.sampleRate))
            let writer = ChunkWriter(dir: dir, format: format, framesPerChunk: framesPerChunk)
            do {
                try lane.read(src, format, control) { try writer.append($0) }
                writer.close()
            } catch {
                writer.close()
                try? FileManager.default.removeItem(at: dir)    // failed split → don't leak the temp chunk dir
                if let e = error as? AudioDecodingError, e == .cancelled || e == .timedOut { throw e }
                lastError = error
                continue
            }
            let urls = writer.urls
            if urls.isEmpty { try? FileManager.default.removeItem(at: dir); continue }   // try the next lane
            return urls
        }
        throw lastError
    }

    public var isChunkingAvailable: Bool { true }

    /// In-app playback rendition. Reuses the same decode lanes that feed WhisperKit to write a mono
    /// Float32 WAV the built-in `AVAudioPlayer` can open — so an imported Telegram Ogg/Opus (or video, whose
    /// original container AVAudioPlayer can't open) is PLAYABLE. This decoder serves both iOS and macOS now.
    /// Compact AAC `.m4a` rendition for the in-app player.
    ///
    /// This used to throw unconditionally, so EVERY note fell through to the PCM WAV fallback — roughly
    /// 11.5 MB per minute for an Opus voice note against AAC's ~0.7. A 45-minute recording alone came to about
    /// 520 MB against a 500 MB cache cap: one long note could evict the entire cache, including itself. The
    /// caller also logged "AAC playback render failed" on every single import, which read as a bug to anyone
    /// tailing the logs and was really just this stub announcing itself.
    ///
    /// Decoded through the same lanes as everything else, then encoded with AVAssetWriter. Note the rendition
    /// keeps the lane's sample rate — 48 kHz for Opus, 16 kHz for the AVAssetReader lane — so video playback is
    /// still mono 16 kHz. That is unchanged here and is a separate improvement; this commit is about the 16×
    /// size difference, which is what was actually breaking the cache.
    public func renderPlayableM4a(from src: URL, to dest: URL) throws {
        var lastError: Error = AudioDecodingError.unsupportedContainer(src.pathExtension)
        for lane in Self.lanes(for: src) {
            guard let format = Self.monoFloatFormat(sampleRate: lane.sampleRate) else { continue }
            do {
                try Self.encodeAAC(src, format: format, lane: lane.read, to: dest)
                return
            } catch {
                try? FileManager.default.removeItem(at: dest)
                lastError = error
            }
        }
        throw lastError
    }

    /// Stream one lane's mono Float32 buffers into an AAC `.m4a`. Nothing is held in memory beyond a buffer at a
    /// time, so a three-hour recording costs the same as a thirty-second one.
    private static func encodeAAC(_ src: URL, format: AVAudioFormat, lane: FrameReader, to dest: URL) throws {
        let writer = try AVAssetWriter(outputURL: dest, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,        // mono speech; the source is already a 16 kHz-class voice note
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw AudioDecodingError.unsupportedContainer(src.pathExtension) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? AudioDecodingError.unsupportedContainer(src.pathExtension) }
        writer.startSession(atSourceTime: .zero)

        var written: AVAudioFramePosition = 0
        do {
            try lane(src, format, nil) { buffer in
                while !input.isReadyForMoreMediaData { usleep(1_000) }
                guard let sample = try Self.sampleBuffer(from: buffer, at: written) else { return }
                guard input.append(sample) else { throw writer.error ?? AudioDecodingError.unsupportedContainer(src.pathExtension) }
                written += AVAudioFramePosition(buffer.frameLength)
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
        input.markAsFinished()

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed, written > 0 else {
            throw writer.error ?? AudioDecodingError.unsupportedContainer(src.pathExtension)
        }
    }

    /// Wrap a PCM buffer as a timed `CMSampleBuffer` the writer can append. `at` is the running frame position,
    /// so the encoder receives a continuous timeline instead of every buffer claiming to start at zero.
    private static func sampleBuffer(from pcm: AVAudioPCMBuffer, at frame: AVAudioFramePosition) throws -> CMSampleBuffer? {
        guard pcm.frameLength > 0 else { return nil }
        var asbd = pcm.format.streamDescription.pointee
        var formatDesc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                             formatDescriptionOut: &formatDesc) == noErr, let formatDesc
        else { throw AudioDecodingError.emptyOutput }   // CoreMedia refused to wrap the buffer

        let scale = CMTimeScale(pcm.format.sampleRate)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: scale),
                                        presentationTimeStamp: CMTime(value: frame, timescale: scale),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDesc,
                                   sampleCount: CMItemCount(pcm.frameLength), sampleTimingEntryCount: 1,
                                   sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                   sampleBufferOut: &sample) == noErr, let sample
        else { throw AudioDecodingError.emptyOutput }   // CoreMedia refused to wrap the buffer
        guard CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
                                                            blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                            flags: 0, bufferList: pcm.mutableAudioBufferList) == noErr
        else { throw AudioDecodingError.emptyOutput }   // CoreMedia refused to wrap the buffer
        return sample
    }
    public func renderPlayableWav(from src: URL, to dest: URL) throws { try Self.writeMonoWav(from: src, to: dest) }

    // MARK: - Lane selection

    /// A lane streams mono Float32 buffers (at `sampleRate`) from `src` into a `sink`, one small buffer at a time.
    private typealias FrameReader = (_ src: URL, _ format: AVAudioFormat, _ control: DecodeControl?,
                                     _ sink: (AVAudioPCMBuffer) throws -> Void) throws -> Void

    /// Candidate lanes for `src`, best first. An Ogg file gets TWO: libopusfile, then AVAssetReader.
    ///
    /// That second one matters. `looksLikeOgg` routes every `OggS` file to opusfile, which decodes Ogg-**Opus**
    /// only — so an Ogg-Vorbis file (also `.ogg`) failed outright, even though AVFoundation reads it perfectly
    /// well. Measured on a synthesised file: AVFoundation reports 1 track / 3.13 s for Ogg-Vorbis. It was a
    /// silent format regression against the previous ffmpeg-era build, and it costs one retry to undo.
    /// (Ogg-FLAC is NOT rescued by this — AVFoundation opens the container but reports 0.00 s, measured. It
    /// simply fails with a clear error instead of a misleading one.)
    private static func lanes(for src: URL) -> [(read: FrameReader, sampleRate: Double)] {
        if looksLikeOgg(src) {
            return [(readOpusFrames, opusSampleRate), (readAVAssetFrames, avAssetSampleRate)]
        }
        return [(readAVAssetFrames, avAssetSampleRate)]
    }

    /// Route to the Opus lane when the extension says so (ogg/oga/opus) OR the file's header carries the Ogg
    /// magic bytes "OggS". Telegram voice messages are frequently saved WITHOUT an extension, and `op_open_file`
    /// parses the container by content anyway (extension-agnostic) — so sniffing restores the ffmpeg-era
    /// "decode by content, not by name" behavior and stops an extension-less Ogg/Opus from wrongly falling to the
    /// AVAssetReader lane (which can't demux Ogg → "no audio decoder available"). Non-Ogg files read 4 bytes and
    /// route to Lane 2 as before. `internal` for unit testing.
    ///
    /// LIMITATION (accepted, like webm/mkv/amr/wma): opusfile decodes ONLY Ogg-**Opus**. An Ogg-Vorbis or Ogg-FLAC
    /// file (also `.ogg`) routes here and `op_open_file` returns `OP_ENOTFORMAT` → a clean decode error (no leak, no
    /// crash). There's no native Vorbis/FLAC-in-Ogg decoder — a general Ogg decoder would mean re-adding ffmpeg,
    /// which Phase 2c deliberately removed. Telegram voice (the target) is always Ogg-Opus, so this is a rare edge.
    static func looksLikeOgg(_ src: URL) -> Bool {
        if opusExtensions.contains(src.pathExtension.lowercased()) { return true }
        guard let fh = try? FileHandle(forReadingFrom: src) else { return false }
        defer { try? fh.close() }
        return ((try? fh.read(upToCount: 4)) ?? Data()) == Data("OggS".utf8)
    }

    /// Cheap duration (seconds) for an Ogg/Opus file via opusfile's index — `op_pcm_total` reads the stream's
    /// total 48 kHz sample count from the Ogg granule positions WITHOUT decoding the audio. This is what lets the
    /// free/Pro length gate measure a Telegram voice message (which AVFoundation can't demux, so `MediaDuration`
    /// returns nil for it — including the very common extension-less case). Returns nil for a non-Ogg file or an
    /// unseekable/broken stream, so the caller falls back to `MediaDuration` (and, failing both, doesn't gate).
    static func oggDurationSeconds(_ src: URL) -> Double? {
        guard looksLikeOgg(src) else { return nil }
        var err: Int32 = 0
        guard let file = op_open_file(src.path, &err), err == 0 else { return nil }
        defer { op_free(file) }
        let total = op_pcm_total(file, -1)          // total samples at 48 kHz across all links; < 0 if unseekable
        guard total > 0 else { return nil }
        return Double(total) / opusSampleRate
    }

    private static func monoFloatFormat(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    }

    /// Decode `src` (either lane) → a mono Float32 WAV at `dest` that AVAudioFile/AVAudioPlayer can open. Shared by
    /// `decodeToWav16k` (temp dest → engine input) and `renderPlayableWav` (cache dest → in-app player). Cleans up a
    /// partial or 0-frame WAV so a failed/empty decode can't masquerade as a valid (silent) file downstream.
    private static func writeMonoWav(from src: URL, to dest: URL, control: DecodeControl? = nil) throws {
        var lastError: Error = AudioDecodingError.unsupportedContainer(src.pathExtension)
        for lane in lanes(for: src) {
            guard let format = monoFloatFormat(sampleRate: lane.sampleRate) else { continue }
            do {
                // The writer MUST go out of scope before the file is read back: `AVAudioFile` flushes on deinit,
                // so validating while it is still alive reads a length of 0 and rejects a perfectly good decode.
                var frames: AVAudioFramePosition = 0
                do {
                    let out = try AVAudioFile(forWriting: dest, settings: format.settings)
                    try lane.read(src, format, control) { try out.write(from: $0) }
                    frames = out.length
                }
                guard frames > 0 else { throw AudioDecodingError.emptyOutput }   // opened fine, produced no audio
                return
            } catch {
                try? FileManager.default.removeItem(at: dest)   // drop a partial WAV so it can't look decoded
                // A cancel or a watchdog trip is the user's/our decision, not "this lane can't read it" — trying
                // the next lane would ignore exactly what the caller asked for.
                if let e = error as? AudioDecodingError, e == .cancelled || e == .timedOut { throw e }
                lastError = error
            }
        }
        throw lastError
    }

    // MARK: - Lane 1 read loop — Ogg/Opus (libopusfile), 48 kHz

    /// `op_open_file` reads the container incrementally from disk; each `op_read_float` page is downmixed to
    /// mono and handed to `sink`. O(one page) memory regardless of length. The single reused `mono` buffer is
    /// safe because `sink` consumes it synchronously (AVAudioFile.write / ChunkWriter copy on write).
    private static func readOpusFrames(_ src: URL, _ format: AVAudioFormat, _ control: DecodeControl?,
                                       _ sink: (AVAudioPCMBuffer) throws -> Void) throws {
        var err: Int32 = 0
        guard let file = op_open_file(src.path, &err), err == 0 else {
            // OP_ENOTFORMAT etc: an Ogg container that is not Ogg-Opus. The caller retries on the AVAssetReader lane.
            throw AudioDecodingError.unsupportedContainer(src.pathExtension)
        }
        defer { op_free(file) }

        let firstChannels = Int(op_channel_count(file, -1))
        guard firstChannels > 0 else { throw AudioDecodingError.corruptStream }   // a link claiming zero channels

        // `op_read_float` never writes past the buffer size we pass, so a fixed buffer is overflow-safe for ANY
        // link's channel count. Size it (and the mono buffer) for the first link's count: that also covers the
        // worst case where a later CHAINED link has fewer channels (a mono link yields up to `capacity` frames,
        // which the mono buffer must be able to hold). Telegram voice is single-link mono → capacity == 5760.
        let capacity = 5760 * firstChannels                                // Opusfile yields ≤ 5760 frames/channel per call
        guard let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)) else {
            throw AudioDecodingError.unsupportedContainer(src.pathExtension)   // buffer alloc — vanishingly rare
        }
        var interleaved = [Float](repeating: 0, count: capacity)

        // A damaged Ogg can return OP_HOLE forever. `continue` on it was an UNBOUNDED retry: one corrupt file
        // and the decode spins until the user force-quits. Gaps are genuinely recoverable, so they are still
        // skipped — just not infinitely.
        var consecutiveHoles = 0
        while true {
            try control?.check()                                           // the user's Cancel, and the watchdog
            var li: Int32 = -1
            let n = interleaved.withUnsafeMutableBufferPointer {
                op_read_float(file, $0.baseAddress, Int32($0.count), &li)   // frames PER CHANNEL; fills `li` (the link)
            }
            if n == OP_HOLE {                                              // recoverable gap (corrupt/missing page)
                consecutiveHoles += 1
                if consecutiveHoles > Self.maxConsecutiveHoles { throw AudioDecodingError.corruptStream }
                continue
            }
            consecutiveHoles = 0
            if n < 0 { throw AudioDecodingError.corruptStream }             // OP_EREAD / OP_EBADPACKET — damaged bytes
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
    private static func readAVAssetFrames(_ src: URL, _ format: AVAudioFormat, _ control: DecodeControl?,
                                          _ sink: (AVAudioPCMBuffer) throws -> Void) throws {
        let asset = AVURLAsset(url: src)
        let audioTracks = asset.tracks(withMediaType: .audio)
        // Prefer an ENABLED audio track over raw track order: multi-audio-track containers (screen recordings =
        // mic + system audio, multi-language m4v) can list a non-default track first, and `.first` would
        // silently transcribe the wrong/silent one. Falls back to the first track when none flags enabled.
        guard let track = audioTracks.first(where: { $0.isEnabled }) ?? audioTracks.first else {
            // Distinguish "we didn't understand this container" from "we understood it and it has no audio".
            // AVURLAsset happily opens ANY file and then reports no tracks, so without this check a junk file and
            // a genuine silent-video both said "no audio track" — one of which is a lie the user can act on wrongly.
            throw asset.tracks.isEmpty ? AudioDecodingError.unsupportedContainer(src.pathExtension)
                                       : AudioDecodingError.noAudioTrack
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcm16kMonoSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioDecodingError.unsupportedContainer(src.pathExtension) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? AudioDecodingError.unsupportedContainer(src.pathExtension) }

        while reader.status == .reading {
            // Cancel/watchdog: without this, `reader.cancelReading()` never happens and a stuck demux runs on.
            do { try control?.check() } catch { reader.cancelReading(); throw error }
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
        if reader.status == .failed { throw reader.error ?? AudioDecodingError.corruptStream }
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
                throw AudioDecodingError.emptyOutput   // slice allocation failed — cannot continue
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
