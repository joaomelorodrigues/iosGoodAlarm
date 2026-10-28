import Foundation

/// UserDefaults keys shared by `@AppStorage` in views and by non-view code.
nonisolated enum AppSettings {
    static let fullSongModeKey = "fullSongMode"
    static let overrideSystemVolumeKey = "overrideSystemVolume"
    static let safetyDelayMinutesKey = "safetyDelayMinutes"
    static let lastSoundIDKey = "lastSoundID"

    static var fullSongMode: Bool {
        UserDefaults.standard.object(forKey: fullSongModeKey) as? Bool ?? true
    }

    static var overrideSystemVolume: Bool {
        UserDefaults.standard.object(forKey: overrideSystemVolumeKey) as? Bool ?? true
    }

    static var safetyDelay: TimeInterval {
        let minutes = UserDefaults.standard.object(forKey: safetyDelayMinutesKey) as? Int ?? 3
        return TimeInterval(minutes * 60)
    }
}

enum FadeOption {
    static let all: [Double] = [0, 5, 10, 15, 20, 30, 60, 120, 180, 300]

    static func label(_ seconds: Double) -> String {
        switch seconds {
        case 0: "Off"
        case ..<60: "\(Int(seconds)) seconds"
        case 60: "1 minute"
        default: "\(Int(seconds / 60)) minutes"
        }
    }

    /// "30s", "2m"
    static func shortLabel(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds))s" : "\(Int(seconds / 60))m"
    }
}

enum SnoozeOption {
    static let all = [1, 2, 3, 5, 10, 15, 20, 25, 30]
}
