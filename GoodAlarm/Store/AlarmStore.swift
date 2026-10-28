@preconcurrency import AlarmKit
import Foundation
import Observation

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

@Observable
final class AlarmStore {
    static let shared = AlarmStore()

    private(set) var alarms: [AlarmItem] = []
    private(set) var authorization: AlarmManager.AuthorizationState
    private(set) var lastError: String?
    var toast: Toast?

    @ObservationIgnored let library = SoundLibrary.shared
    @ObservationIgnored let scheduler = AlarmScheduler()
    @ObservationIgnored private var engine: RingEngine { .shared }
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var needsResync = false
    @ObservationIgnored private let fileURL = AppPaths.support.appending(path: "alarms.json")

    init() {
        authorization = scheduler.authorizationState
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([AlarmItem].self, from: data) {
            alarms = saved
        }
        Task { [weak self] in
            for await systemAlarms in AlarmManager.shared.alarmUpdates {
                self?.systemAlarmsChanged(systemAlarms)
            }
        }
    }

    func alarm(withID id: UUID) -> AlarmItem? {
        alarms.first { $0.id == id }
    }

    /// The soonest enabled alarm and when it rings.
    var nextAlarm: (item: AlarmItem, date: Date)? {
        alarms
            .filter(\.isEnabled)
            .compactMap { item in item.nextOccurrence(after: .now).map { (item, $0) } }
            .min { $0.1 < $1.1 }
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        await library.prepareBuiltIns()
        authorization = await scheduler.requestAuthorization()
        await sync()
    }

    func appBecameActive() async {
        authorization = scheduler.authorizationState
        await sync()
    }

    func requestAuthorization() async {
        authorization = await scheduler.requestAuthorization()
        await sync()
    }

    // MARK: - Editing

    func save(_ draft: AlarmItem, skipNext: Bool) {
        var item = draft
        item.isEnabled = true
        if item.isRepeating {
            item.oneTimeDate = nil
            item.deleteAfterRinging = false
            item.skippedOccurrence = nil
            if skipNext { item.skippedOccurrence = item.nextOccurrence(after: .now) }
        } else {
            item.skippedOccurrence = nil
            item.oneTimeDate = AlarmItem.nextDate(hour: item.hour, minute: item.minute, after: .now)
        }
        UserDefaults.standard.set(item.soundID, forKey: AppSettings.lastSoundIDKey)

        if let index = alarms.firstIndex(where: { $0.id == item.id }) {
            alarms[index] = item
        } else {
            alarms.append(item)
        }
        resetSystemState(for: item.id)
        persist()
        announce(item)
        Task { await sync() }
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        update(id) { item in
            item.isEnabled = enabled
            item.skippedOccurrence = nil
            if enabled && !item.isRepeating {
                item.oneTimeDate = AlarmItem.nextDate(hour: item.hour, minute: item.minute, after: .now)
            }
        }
        resetSystemState(for: id)
        if enabled, let item = alarm(withID: id) { announce(item) }
        Task { await sync() }
    }

    func delete(_ id: UUID) {
        alarms.removeAll { $0.id == id }
        resetSystemState(for: id)
        persist()
        Task { await sync() }
    }

    func duplicate(_ id: UUID) {
        guard var copy = alarm(withID: id) else { return }
        copy.id = UUID()
        copy.skippedOccurrence = nil
        save(copy, skipNext: false)
    }

    /// Google Clock's "Skip" / "Dismiss early": skip the next ring of a repeating alarm,
    /// or switch a one-time alarm off.
    func toggleSkipNext(_ id: UUID) {
        guard let item = alarm(withID: id) else { return }
        guard item.isRepeating else {
            setEnabled(false, for: id)
            toast = Toast(message: "Alarm dismissed")
            return
        }
        if item.hasActiveSkip {
            update(id) { $0.skippedOccurrence = nil }
            toast = Toast(message: "Skip undone")
        } else if let next = item.nextOccurrence(after: .now) {
            update(id) { $0.skippedOccurrence = next }
            let following = alarm(withID: id)?.nextOccurrence(after: .now)
            let message = following.map { "Skipping \(TimeFormat.day(next, midSentence: true)) · next ring \(TimeFormat.day($0, midSentence: true)) \(TimeFormat.clock($0))" }
            toast = Toast(message: message ?? "Next alarm skipped")
        }
        engine.cancel(itemID: id)
        Task { await sync() }
    }

    /// Android-style quick nap: a one-off alarm N minutes from now that cleans up after itself.
    func addNap(minutes: Int) {
        let date = Date.now.addingTimeInterval(TimeInterval(minutes * 60))
        var item = AlarmItem.new(at: date)
        item.label = "Nap · \(minutes) min"
        item.oneTimeDate = date
        item.deleteAfterRinging = true
        item.fadeInSeconds = 10
        alarms.append(item)
        persist()
        announce(item)
        Task { await sync() }
    }

    func testSystemAlarm(_ item: AlarmItem) async {
        do {
            try await scheduler.scheduleTest(for: item, library: library)
            toast = Toast(message: "Test alarm in 10 seconds — lock your phone to try it")
        } catch {
            toast = Toast(message: "Couldn't schedule the test: \(error.localizedDescription)")
        }
    }

    func soundRemoved(_ soundID: String) {
        for alarm in alarms where alarm.soundID == soundID {
            update(alarm.id) { $0.soundID = SoundItem.defaultID; $0.startOffset = 0 }
        }
        Task { await sync() }
    }

    // MARK: - System alarm callbacks

    func systemAlarmStopped(systemID: UUID, itemID: UUID?) async {
        if let backupOwner = scheduler.itemID(forBackup: systemID) {
            engine.cancel(itemID: backupOwner)
        }
        scheduler.systemAlarmStopped(systemID)
        if let itemID, let item = alarm(withID: itemID), !item.isRepeating {
            finishOneTime(item)
        }
        await sync()
    }

    private func systemAlarmsChanged(_ systemAlarms: [Alarm]) {
        // A safety alarm went off while full-song mode was ringing: hand over to the system.
        for alarm in systemAlarms where alarm.state == .alerting {
            if let itemID = scheduler.itemID(forBackup: alarm.id) { engine.cancel(itemID: itemID) }
        }
    }

    // MARK: - Full-song mode hand-off

    func beginInAppRing(itemID: UUID, occurrence: Date) {
        scheduler.suppress(itemID: itemID, occurrence: occurrence)
        Task {
            await sync()
            if let item = alarm(withID: itemID) {
                await scheduler.scheduleBackup(for: item, at: occurrence.addingTimeInterval(AppSettings.safetyDelay), library: library)
            }
        }
    }

    func inAppRingSnoozed(itemID: UUID, until: Date) {
        guard let item = alarm(withID: itemID) else { return }
        Task { await scheduler.scheduleBackup(for: item, at: until.addingTimeInterval(AppSettings.safetyDelay), library: library) }
    }

    func inAppRingFinished(itemID: UUID) {
        scheduler.cancelBackup(for: itemID)
        if let item = alarm(withID: itemID), !item.isRepeating { finishOneTime(item) }
        Task { await sync() }
    }

    // MARK: - Sync

    func sync() async {
        if isSyncing {
            needsResync = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            needsResync = false
            expireFinishedOneTimeAlarms()
            await scheduler.sync(alarms: alarms, library: library)
            authorization = scheduler.authorizationState
            lastError = scheduler.lastError
        } while needsResync
    }

    private func expireFinishedOneTimeAlarms() {
        let active = scheduler.activeItemIDs()
        let cutoff = Date.now.addingTimeInterval(-60)
        for item in alarms where item.isEnabled && !item.isRepeating {
            guard let date = item.oneTimeDate, date < cutoff, !active.contains(item.id), !engine.isBusy(with: item.id) else { continue }
            finishOneTime(item)
        }
    }

    private func finishOneTime(_ item: AlarmItem) {
        if item.deleteAfterRinging {
            alarms.removeAll { $0.id == item.id }
            persist()
        } else {
            update(item.id) { $0.isEnabled = false }
        }
    }

    // MARK: - Helpers

    private func resetSystemState(for id: UUID) {
        scheduler.cancelAll(for: id)
        engine.cancel(itemID: id)
    }

    private func update(_ id: UUID, _ change: (inout AlarmItem) -> Void) {
        guard let index = alarms.firstIndex(where: { $0.id == id }) else { return }
        change(&alarms[index])
        persist()
    }

    private func persist() {
        alarms.sort { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        if let data = try? JSONEncoder().encode(alarms) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func announce(_ item: AlarmItem) {
        guard let date = item.nextOccurrence(after: .now) else { return }
        toast = Toast(message: "Alarm set for \(TimeFormat.relative(to: date)) from now")
    }
}
