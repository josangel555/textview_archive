import Foundation
import AVFoundation

public enum AudioDecodeError: Error, Equatable {
    case unreadable        // AVAudioFile couldn't open the URL (missing / not audio)
    case unsupportedFormat // no float channel data (unexpected processing format)
    case empty             // zero frames
    case tooLarge          // frame count exceeds what we decode in one buffer
}

/// Decode an audio file to an `AudioPCMBuffer` (deinterleaved float PCM) using
/// `AVAudioFile` — a system framework, so no third-party dependency and no
/// audio hardware / `AVAudioSession`: this is pure file I/O and is safe on the
/// headless test host. Supports every container/codec AVFoundation reads
/// (WAV, AIFF, CAF, MP3, AAC/M4A, FLAC, …).
///
/// Slice-1 decodes the whole file into memory in one pass. For very large
/// files that's a lot of RAM (≈ frames × channels × 4 bytes); a streaming /
/// decode-to-peaks path is a follow-up (the waveform only needs the reduction,
/// not the full buffer). `maxFrames` bounds the one-shot decode defensively.
public enum AudioDecoder {

    /// ~30 min of 48 kHz stereo (≈ 350 MB of float PCM). Beyond this, callers
    /// should stream; we refuse rather than blow up memory.
    public static let defaultMaxFrames: Int = 48_000 * 60 * 30

    public static func decode(
        contentsOf url: URL,
        maxFrames: Int = defaultMaxFrames
    ) throws -> AudioPCMBuffer {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioDecodeError.unreadable
        }

        let format = file.processingFormat       // float32, deinterleaved, file's rate/channels
        let length = file.length                  // AVAudioFramePosition (Int64)
        guard length > 0 else { throw AudioDecodeError.empty }
        guard length <= Int64(maxFrames), length <= Int64(AVAudioFrameCount.max) else {
            throw AudioDecodeError.tooLarge
        }

        let frames = AVAudioFrameCount(length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw AudioDecodeError.unsupportedFormat
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw AudioDecodeError.unreadable
        }

        let n = Int(buffer.frameLength)
        guard n > 0 else { throw AudioDecodeError.empty }
        guard let channelData = buffer.floatChannelData else {
            throw AudioDecodeError.unsupportedFormat
        }

        let channelCount = Int(format.channelCount)
        var channels: [[Float]] = []
        channels.reserveCapacity(channelCount)
        for c in 0..<channelCount {
            channels.append(Array(UnsafeBufferPointer(start: channelData[c], count: n)))
        }
        return AudioPCMBuffer(sampleRate: format.sampleRate, channels: channels)
    }
}
