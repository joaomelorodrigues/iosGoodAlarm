import AVFoundation
import Observation

/// AVAudioPlayer with a perceptual fade-in. Used for previews and for full-song ringing.
@Observable
final class FadingPlayer {
    private(set) var playingURL: URL?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var rampTimer: Timer?
    @ObservationIgnored private var amplitude: Float = 1
    @ObservationIgnored private var rampProgress: Float = 1

    var isPlaying: Bool { playingURL != nil }

    func play(url: URL, from offset: Double = 0, amplitude: Float, fadeIn: Double = 0, loops: Bool = true) throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: url)
        player.numberOfLoops = loops ? -1 : 0
        player.currentTime = min(max(0, offset), max(0, player.duration - 1))
        self.amplitude = amplitude
        rampProgress = fadeIn > 0 ? 0 : 1
        player.volume = amplitude * rampProgress
        player.prepareToPlay()
        player.play()
        self.player = player
        playingURL = url

        guard fadeIn > 0 else { return }
        let start = Date()
        rampTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                let x = Float(min(1, Date().timeIntervalSince(start) / fadeIn))
                self.rampProgress = x * x
                player.volume = self.amplitude * self.rampProgress
                if x >= 1 { self.rampTimer?.invalidate() }
            }
        }
    }

    /// Changes the target loudness without restarting the fade.
    func setAmplitude(_ amplitude: Float) {
        self.amplitude = amplitude
        player?.volume = amplitude * rampProgress
    }

    func resume() { player?.play() }

    func stop() {
        rampTimer?.invalidate()
        rampTimer = nil
        player?.stop()
        player = nil
        playingURL = nil
    }

    /// Previews and the overnight keep-alive share one mixable session, so neither can be
    /// interrupted by (or interrupt) other apps. Only a real ring takes the session exclusively.
    static func activatePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }
}
