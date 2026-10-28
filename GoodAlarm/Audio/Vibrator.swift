import AudioToolbox
import Foundation

/// Repeats the system vibration in a pattern. Uses AudioServices rather than Core Haptics
/// because Core Haptics stops when the app is in the background, which is when alarms ring.
final class Vibrator {
    private var timer: Timer?
    private var step = 0
    private var start = Date()

    var isRunning: Bool { timer != nil }

    /// Vibrates until `stop()`, or for `duration` seconds if given.
    func start(_ pattern: VibrationPattern, duration: TimeInterval? = nil) {
        stop()
        guard Haptics.isSupported else { return }
        step = 0
        start = .now
        buzz(pattern, until: duration.map { start.addingTimeInterval($0) })
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func buzz(_ pattern: VibrationPattern, until end: Date?) {
        if let end, Date.now >= end {
            stop()
            return
        }
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        let gap = pattern.gap(afterStep: step, elapsed: Date.now.timeIntervalSince(start))
        step += 1
        timer = Timer.scheduledTimer(withTimeInterval: gap, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.buzz(pattern, until: end) }
        }
    }
}
