@preconcurrency import AlarmKit
import AppIntents

/// Runs in the app's process when a system alarm is stopped, even if the app wasn't running.
struct StopAlarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop alarm"
    static let isDiscoverable = false

    @Parameter(title: "System alarm ID")
    var systemID: String

    @Parameter(title: "Alarm ID")
    var itemID: String

    init() {}

    init(systemID: UUID, itemID: UUID?) {
        self.systemID = systemID.uuidString
        self.itemID = itemID?.uuidString ?? ""
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: systemID) else { return .result() }
        try? AlarmManager.shared.stop(id: id)
        await AlarmStore.shared.systemAlarmStopped(systemID: id, itemID: UUID(uuidString: itemID))
        return .result()
    }
}

struct SnoozeAlarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Snooze alarm"
    static let isDiscoverable = false

    @Parameter(title: "System alarm ID")
    var systemID: String

    init() {}

    init(systemID: UUID) {
        self.systemID = systemID.uuidString
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: systemID) {
            try? AlarmManager.shared.countdown(id: id)
        }
        return .result()
    }
}
