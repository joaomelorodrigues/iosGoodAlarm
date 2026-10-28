import CoreHaptics

/// Vibration rhythms for full-song mode. Each buzz is the system's standard vibration;
/// a pattern only decides the gap before the next one.
nonisolated enum VibrationPattern: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard, heartbeat, rapid, escalating

    var id: String { rawValue }

    var name: String {
        switch self {
        case .standard: "Standard"
        case .heartbeat: "Heartbeat"
        case .rapid: "Rapid"
        case .escalating: "Escalating"
        }
    }

    /// Seconds to wait after buzz number `step`, which happened `elapsed` seconds into the ring.
    func gap(afterStep step: Int, elapsed: TimeInterval) -> TimeInterval {
        switch self {
        case .standard: 1.4
        case .heartbeat: step.isMultiple(of: 2) ? 0.45 : 1.4
        case .rapid: 0.6
        case .escalating: max(0.6, 4 - elapsed / 10)
        }
    }
}

nonisolated enum Haptics {
    /// False on iPads, the simulator and other devices without a vibration motor.
    static let isSupported: Bool = {
        #if DEBUG
        // Lets UI tests exercise the iPhone layout on hardware that can't vibrate.
        if ProcessInfo.processInfo.arguments.contains("-GAForceHaptics") { return true }
        #endif
        return CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }()
}
