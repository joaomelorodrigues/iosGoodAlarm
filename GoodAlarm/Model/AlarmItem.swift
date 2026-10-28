import Foundation

nonisolated struct AlarmItem: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var hour: Int
    var minute: Int
    var label = ""
    /// Calendar weekday numbers (1 = Sunday … 7 = Saturday). Empty means a one-time alarm.
    var repeatDays: Set<Int> = []
    var isEnabled = true
    var soundID = SoundItem.defaultID
    /// Perceived loudness, 0…1.
    var volume = 0.8
    var fadeInSeconds: Double = 30
    /// Where playback starts inside the track, in seconds.
    var startOffset: Double = 0
    var snoozeEnabled = true
    var snoozeMinutes = 10
    var deleteAfterRinging = false
    /// Off means vibrate only.
    var soundEnabled = true
    var vibrate = true
    var vibrationPattern = VibrationPattern.standard
    /// One-time alarms only: the exact moment it rings.
    var oneTimeDate: Date?
    /// Repeating alarms only: a single occurrence the user chose to skip.
    var skippedOccurrence: Date?

    var isRepeating: Bool { !repeatDays.isEmpty }
    var displayLabel: String { label.isEmpty ? "Alarm" : label }
    /// A silent alarm on a device that can't vibrate would wake no one.
    var isVibrateOnly: Bool { !soundEnabled && Haptics.isSupported }

    static func new(at date: Date = .now.addingTimeInterval(3600)) -> AlarmItem {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        var item = AlarmItem(hour: parts.hour ?? 7, minute: parts.minute ?? 0)
        if let last = UserDefaults.standard.string(forKey: AppSettings.lastSoundIDKey) {
            item.soundID = last
        }
        return item
    }
}

// MARK: - Decoding

nonisolated extension AlarmItem {
    /// Tolerates missing keys so alarms saved by older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(hour: try c.decode(Int.self, forKey: .hour), minute: try c.decode(Int.self, forKey: .minute))
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? id
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? label
        repeatDays = try c.decodeIfPresent(Set<Int>.self, forKey: .repeatDays) ?? repeatDays
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        soundID = try c.decodeIfPresent(String.self, forKey: .soundID) ?? soundID
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? volume
        fadeInSeconds = try c.decodeIfPresent(Double.self, forKey: .fadeInSeconds) ?? fadeInSeconds
        startOffset = try c.decodeIfPresent(Double.self, forKey: .startOffset) ?? startOffset
        snoozeEnabled = try c.decodeIfPresent(Bool.self, forKey: .snoozeEnabled) ?? snoozeEnabled
        snoozeMinutes = try c.decodeIfPresent(Int.self, forKey: .snoozeMinutes) ?? snoozeMinutes
        deleteAfterRinging = try c.decodeIfPresent(Bool.self, forKey: .deleteAfterRinging) ?? deleteAfterRinging
        soundEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundEnabled) ?? soundEnabled
        vibrate = try c.decodeIfPresent(Bool.self, forKey: .vibrate) ?? vibrate
        vibrationPattern = try c.decodeIfPresent(VibrationPattern.self, forKey: .vibrationPattern) ?? vibrationPattern
        oneTimeDate = try c.decodeIfPresent(Date.self, forKey: .oneTimeDate)
        skippedOccurrence = try c.decodeIfPresent(Date.self, forKey: .skippedOccurrence)
    }
}

// MARK: - Occurrences

nonisolated extension AlarmItem {
    static func nextDate(hour: Int, minute: Int, after date: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(
            after: date,
            matching: DateComponents(hour: hour, minute: minute, second: 0),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ) ?? date.addingTimeInterval(86_400)
    }

    /// The next moment this alarm rings, honoring skips and the given exclusions.
    /// Ignores `isEnabled`, so it can also describe a switched-off alarm.
    func nextOccurrence(after date: Date = .now, excluding extra: [Date] = [], calendar: Calendar = .current) -> Date? {
        func isExcluded(_ candidate: Date, _ list: [Date]) -> Bool {
            list.contains { abs($0.timeIntervalSince(candidate)) < 60 }
        }
        guard isRepeating else {
            guard let oneTimeDate, oneTimeDate > date, !isExcluded(oneTimeDate, extra) else { return nil }
            return oneTimeDate
        }
        let excluded = extra + [skippedOccurrence].compactMap { $0 }
        var cursor = date
        for _ in 0..<16 {
            let candidate = Self.nextDate(hour: hour, minute: minute, after: cursor, calendar: calendar)
            if repeatDays.contains(calendar.component(.weekday, from: candidate)), !isExcluded(candidate, excluded) {
                return candidate
            }
            cursor = candidate
        }
        return nil
    }

    /// What the list shows: when it would ring if it were on.
    func displayDate(now: Date = .now) -> Date? {
        if isRepeating { return nextOccurrence(after: now) }
        if isEnabled, let oneTimeDate, oneTimeDate > now { return oneTimeDate }
        return Self.nextDate(hour: hour, minute: minute, after: now)
    }

    var hasActiveSkip: Bool {
        guard isRepeating, let skippedOccurrence else { return false }
        return skippedOccurrence > .now
    }
}

// MARK: - Weekdays

nonisolated extension AlarmItem {
    /// Weekday numbers in the order the user's calendar starts the week.
    static func orderedWeekdays(_ calendar: Calendar = .current) -> [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }

    func repeatSummary(calendar: Calendar = .current) -> String {
        switch repeatDays {
        case []: return ""
        case Set(1...7): return "Every day"
        case [2, 3, 4, 5, 6]: return "Weekdays"
        case [1, 7]: return "Weekends"
        default:
            let symbols = calendar.shortWeekdaySymbols
            return Self.orderedWeekdays(calendar)
                .filter(repeatDays.contains)
                .map { symbols[$0 - 1] }
                .joined(separator: ", ")
        }
    }
}
