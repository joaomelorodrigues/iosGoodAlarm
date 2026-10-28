import AVFoundation

/// AlarmKit can't change volume and only plays sounds shorter than 30 s, so the alarm's
/// volume, fade-in and start position are rendered into a short clip in Library/Sounds.
nonisolated enum ClipRenderer {
    static let clipSeconds = 29.0
    /// The clip loops while ringing, so a fade longer than this would make every loop quiet again.
    static let maxBakedFade = 20.0

    /// Slider position → amplitude. Squaring makes the slider feel even across its range.
    static func amplitude(forVolume volume: Double) -> Float {
        Float(max(0, min(1, volume)) * max(0, min(1, volume)))
    }

    static let silentClipName = "ga-silent-v1.caf"

    static func writeSilence(to url: URL, seconds: Double) throws {
        let sampleRate = 22_050.0
        let frames = AVAudioFrameCount(seconds * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frames
        buffer.floatChannelData?[0].update(repeating: 0, count: Int(frames))
        let file = try AVAudioFile(forWriting: url, settings: pcm16Settings(sampleRate: sampleRate, channels: 1),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    static func clipName(for item: AlarmItem, sound: SoundItem) -> String {
        let key = [
            sound.id,
            String(Int((item.volume * 100).rounded())),
            String(Int(min(item.fadeInSeconds, maxBakedFade))),
            String(Int(item.startOffset)),
            "v1",
        ].joined(separator: "|")
        return "ga-\(stableHash(key)).caf"
    }

    @concurrent
    static func render(source: URL, to destination: URL, startOffset: Double, volume: Double, fadeIn: Double) async throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let sampleRate = format.sampleRate
        guard input.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let totalFrames = AVAudioFramePosition(clipSeconds * sampleRate)
        let gain = amplitude(forVolume: volume)
        let fade = min(fadeIn, maxBakedFade)
        let tail = 0.25 // short fade-out so the loop seam doesn't click
        input.framePosition = max(0, min(AVAudioFramePosition(startOffset * sampleRate), input.length - 1))

        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        do {
            let output = try AVAudioFile(forWriting: partial,
                                         settings: pcm16Settings(sampleRate: sampleRate, channels: format.channelCount),
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            var written: AVAudioFramePosition = 0
            var emptyReads = 0
            while written < totalFrames {
                if input.framePosition >= input.length { input.framePosition = 0 }
                let want = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), totalFrames - written))
                try input.read(into: buffer, frameCount: want)
                let frames = Int(buffer.frameLength)
                if frames == 0 {
                    emptyReads += 1
                    if emptyReads > 2 { break }
                    input.framePosition = 0
                    continue
                }
                for frame in 0..<frames {
                    let t = Double(written + AVAudioFramePosition(frame)) / sampleRate
                    let x = fade > 0 ? min(1, t / fade) : min(1, t / 0.01)
                    let out = min(1, (clipSeconds - t) / tail)
                    let g = gain * Float(x * x * max(0, out))
                    for channel in 0..<Int(format.channelCount) {
                        buffer.floatChannelData![channel][frame] *= g
                    }
                }
                try output.write(from: buffer)
                written += AVAudioFramePosition(frames)
            }
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }
}

/// FNV-1a, stable across launches (unlike `Hasher`).
nonisolated func stableHash(_ string: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x100_0000_01b3
    }
    return String(hash, radix: 16)
}
