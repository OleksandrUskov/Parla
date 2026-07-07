import Foundation
import opus

/// In-process Ogg/Opus decode for iOS (iOS-port P1.3, IOS_PORT §2) via Opusfile (sbooth opus + ogg
/// xcframeworks) — the replacement for the macOS ffmpeg subprocess, which is impossible on iOS. Yields mono
/// Float PCM at 48 kHz; WhisperKit's `transcribe(audioArray:)` resamples to 16 kHz itself, so no on-disk WAV.
///
/// ⚠️ P1.3 SEED: this materializes the whole file in RAM. The production path must STREAM page-by-page — a
/// 70-min Opus ≈ 200M floats ≈ ~800 MB → jetsam (IOS_PORT §2 memory warning). Chunk incrementally before
/// shipping long audio on iOS. This first cut proves the codec path end-to-end (verified by OpusDecodeTests).
enum OpusAudioDecoder {

    /// Decode an in-memory Ogg/Opus file to mono 48 kHz Float PCM. Returns nil on any Opusfile error.
    /// The whole decode runs inside `withUnsafeBytes` so the backing buffer stays valid for the OggOpusFile's
    /// lifetime (op_open_memory reads from the caller's memory).
    static func decodeToMono48k(_ data: Data) -> [Float]? {
        data.withUnsafeBytes { raw -> [Float]? in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
            var err: Int32 = 0
            guard let file = op_open_memory(base, data.count, &err), err == 0 else { return nil }
            defer { op_free(file) }

            let channels = Int(op_channel_count(file, -1))
            guard channels > 0 else { return nil }

            let framesPerCall = 5760                       // op_read_float yields ≤ 120 ms/channel per call
            var interleaved = [Float](repeating: 0, count: framesPerCall * channels)
            var mono: [Float] = []
            let total = op_pcm_total(file, -1)             // total samples/channel, or negative if unknown
            if total > 0 { mono.reserveCapacity(Int(total)) }

            while true {
                let framesRead = interleaved.withUnsafeMutableBufferPointer { buf in
                    op_read_float(file, buf.baseAddress, Int32(buf.count), nil)
                }
                if framesRead < 0 { return nil }           // decode error
                if framesRead == 0 { break }               // EOF
                let n = Int(framesRead)
                if channels == 1 {
                    mono.append(contentsOf: interleaved[0 ..< n])
                } else {
                    for f in 0 ..< n {                     // downmix to mono (WhisperKit wants mono)
                        var acc: Float = 0
                        for c in 0 ..< channels { acc += interleaved[f * channels + c] }
                        mono.append(acc / Float(channels))
                    }
                }
            }
            return mono
        }
    }
}
