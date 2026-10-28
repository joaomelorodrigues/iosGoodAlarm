import AVFoundation

/// Built-in alarm tones, synthesized on first launch so the app ships without audio assets.
nonisolated enum BuiltInTone: String, CaseIterable, Sendable {
    case sunrise, bells, pulse, classic

    var name: String {
        switch self {
        case .sunrise: "Sunrise"
        case .bells: "Morning Bells"
        case .pulse: "Soft Pulse"
        case .classic: "Classic Beep"
        }
    }

    var fileName: String { "builtin-\(rawValue).caf" }

    var soundItem: SoundItem {
        SoundItem(id: "builtin-\(rawValue)", name: name, subtitle: "Built-in", kind: .builtIn,
                  fileName: fileName, duration: ToneSynth.duration(of: self))
    }
}

nonisolated enum ToneSynth {
    static let sampleRate = 44_100.0

    static func duration(of tone: BuiltInTone) -> Double {
        switch tone {
        case .sunrise: 9.6
        case .bells: 9.6
        case .pulse: 8
        case .classic: 6.4
        }
    }

    static func write(_ tone: BuiltInTone, to url: URL) throws {
        let samples = synthesize(tone)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = buffer.floatChannelData![0]
        for i in samples.indices { channel[i] = samples[i] }
        let file = try AVAudioFile(forWriting: url, settings: pcm16Settings(sampleRate: sampleRate, channels: 1),
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    private static func synthesize(_ tone: BuiltInTone) -> [Float] {
        var out = [Float](repeating: 0, count: Int(duration(of: tone) * sampleRate))
        switch tone {
        case .sunrise:
            // Rising major arpeggios, each phrase a step brighter.
            let phrases: [[Double]] = [
                [523.25, 659.25, 783.99, 1046.5],
                [587.33, 739.99, 880.00, 1174.66],
                [659.25, 830.61, 987.77, 1318.51],
                [698.46, 880.00, 1046.5, 1396.91],
            ]
            for (p, notes) in phrases.enumerated() {
                for (n, freq) in notes.enumerated() {
                    bell(&out, at: Double(p) * 2.4 + Double(n) * 0.28, freq: freq, length: 1.8, amp: 0.5)
                }
            }
        case .bells:
            for i in 0..<4 {
                let t = Double(i) * 2.4
                bell(&out, at: t, freq: 659.25, length: 2.2, amp: 0.6)
                bell(&out, at: t + 0.6, freq: 523.25, length: 2.2, amp: 0.6)
            }
        case .pulse:
            for i in 0..<8 {
                swell(&out, at: Double(i), freqs: [440, 659.25], length: 0.8, amp: 0.45)
            }
        case .classic:
            for group in 0..<5 {
                for beep in 0..<4 {
                    square(&out, at: Double(group) * 1.28 + Double(beep) * 0.16, freq: 1046.5, length: 0.09, amp: 0.35)
                }
            }
        }
        let peak = out.map(abs).max() ?? 1
        let scale = peak > 0 ? 0.9 / peak : 1
        return out.map { $0 * scale }
    }

    private static func bell(_ out: inout [Float], at start: Double, freq: Double, length: Double, amp: Double) {
        let partials: [(ratio: Double, gain: Double, decay: Double)] = [(1, 1, 3), (2, 0.4, 5), (3.01, 0.2, 8), (4.2, 0.1, 11)]
        render(&out, at: start, length: length) { t in
            let attack = min(1, t / 0.004)
            return partials.reduce(0) { sum, p in
                sum + p.gain * exp(-t * p.decay / length) * sin(2 * .pi * freq * p.ratio * t)
            } * attack * amp
        }
    }

    private static func swell(_ out: inout [Float], at start: Double, freqs: [Double], length: Double, amp: Double) {
        render(&out, at: start, length: length) { t in
            let envelope = sin(.pi * t / length)
            return freqs.reduce(0) { $0 + sin(2 * .pi * $1 * t) } / Double(freqs.count) * envelope * envelope * amp
        }
    }

    private static func square(_ out: inout [Float], at start: Double, freq: Double, length: Double, amp: Double) {
        render(&out, at: start, length: length) { t in
            let edge = min(1, t / 0.003, (length - t) / 0.003)
            let w = 2 * .pi * freq * t
            return (sin(w) + sin(3 * w) / 3 + sin(5 * w) / 5) * edge * amp
        }
    }

    private static func render(_ out: inout [Float], at start: Double, length: Double, _ sample: (Double) -> Double) {
        let first = Int(start * sampleRate)
        let count = Int(length * sampleRate)
        for i in 0..<count where first + i < out.count {
            out[first + i] += Float(sample(Double(i) / sampleRate))
        }
    }
}

/// 16-bit linear PCM, the safest format for system alarm sounds.
nonisolated func pcm16Settings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
    [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
}
