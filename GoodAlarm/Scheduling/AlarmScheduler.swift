import ActivityKit
@preconcurrency import AlarmKit
import SwiftUI

/// Mirrors the app's alarms into AlarmKit, the only API that lets a third-party alarm ring
/// through silent mode, Focus and a closed app.
///
/// One app alarm can map to several system alarms. Skipping one occurrence of a weekly alarm
/// takes that weekday out of the weekly alarm and adds a one-off for the following week, so a
/// skip never depends on the app running later to undo it.
final class AlarmScheduler {
    nonisolated enum Spec: Hashable, Sendable {
        case fixed(Date)
        case weekly(hour: Int, minute: Int, days: [Int])

        var key: String {
            switch self {
            case .fixed(let date): "F\(Int(date.timeIntervalSince1970))"
            case let .weekly(hour, minute, days): "W\(hour):\(minute):\(days.map(String.init).joined(separator: ","))"
            }
        }

        var schedule: Alarm.Schedule {
            switch self {
            case .fixed(let date):
                .fixed(date)
            case let .weekly(hour, minute, days):
                .relative(.init(time: .init(hour: hour, minute: minute), repeats: .weekly(days.map(Self.weekday))))
            }
        }

        private static func weekday(_ number: Int) -> Locale.Weekday {
            [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday][(number - 1) % 7]
        }
    }

    private nonisolated struct Record: Codable {
        var systemIDs: [UUID]
        var signature: String
        var clipName: String?
    }

    private nonisolated struct Extra: Codable {
        var systemID: UUID
        var clipName: String?
        var created: Date
    }

    private nonisolated struct State: Codable {
        var records: [UUID: Record] = [:]
        /// Occurrences that full-song mode is ringing in-app instead of the system.
        var suppressions: [UUID: Date] = [:]
        /// Safety alarms behind an in-app ring, keyed by app alarm.
        var backups: [UUID: Extra] = [:]
        /// "Test in 10 seconds" alarms, keyed by system alarm.
        var tests: [UUID: Extra] = [:]
    }

    private let manager = AlarmManager.shared
    private var state = State()
    private(set) var lastError: String?
    private let stateURL = AppPaths.support.appending(path: "scheduler.json")

    init() {
        if let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        }
    }

    var authorizationState: AlarmManager.AuthorizationState { manager.authorizationState }

    private var systemAlarms: [Alarm] { (try? manager.alarms) ?? [] }

    func requestAuthorization() async -> AlarmManager.AuthorizationState {
        if manager.authorizationState == .notDetermined {
            _ = try? await manager.requestAuthorization()
        }
        return manager.authorizationState
    }

    // MARK: - Sync

    func sync(alarms items: [AlarmItem], library: SoundLibrary) async {
        let now = Date()
        state.suppressions = state.suppressions.filter { $0.value > now.addingTimeInterval(-90) }
        state.tests = state.tests.filter { $0.value.created > now.addingTimeInterval(-900) }
        guard manager.authorizationState == .authorized else { return }
        lastError = nil

        let live = Dictionary(systemAlarms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // A safety alarm only makes sense while its alarm still exists and is on.
        let enabledIDs = Set(items.filter(\.isEnabled).map(\.id))
        for (itemID, backup) in state.backups where !enabledIDs.contains(itemID) {
            if let alarm = live[backup.systemID], alarm.state != .scheduled { continue }
            try? manager.cancel(id: backup.systemID)
            state.backups[itemID] = nil
        }
        var keep = Set(state.backups.values.map(\.systemID)).union(state.tests.keys)

        for item in items {
            let existing = state.records[item.id]
            // Ringing or snoozed right now: leave it alone so we don't cut it off.
            if let existing, existing.systemIDs.contains(where: { live[$0].map { $0.state != .scheduled } ?? false }) {
                keep.formUnion(existing.systemIDs)
                continue
            }
            guard item.isEnabled else {
                cancel(existing?.systemIDs ?? [])
                state.records[item.id] = nil
                continue
            }

            let specs = Self.specs(for: item, excluding: [state.suppressions[item.id]].compactMap { $0 }, now: now)
            let clip = clipPlan(for: item, library: library)
            let signature = (specs.map(\.key) + [
                clip.name ?? "default", item.displayLabel, item.snoozeEnabled ? "\(item.snoozeMinutes)" : "-",
            ]).joined(separator: "|")

            if let existing, existing.signature == signature, existing.systemIDs.allSatisfy({ live[$0] != nil }) {
                keep.formUnion(existing.systemIDs)
                continue
            }

            cancel(existing?.systemIDs ?? [])
            state.records[item.id] = nil
            do {
                let soundName = try await prepareClip(clip.name, item: item, sound: clip.sound, library: library)
                var ids: [UUID] = []
                for spec in specs {
                    let id = UUID()
                    _ = try await manager.schedule(id: id, configuration: configuration(
                        for: item, systemID: id, schedule: spec.schedule, soundName: soundName, soundTitle: clip.title))
                    ids.append(id)
                }
                state.records[item.id] = Record(systemIDs: ids, signature: signature, clipName: soundName)
                keep.formUnion(ids)
            } catch {
                lastError = "Couldn't schedule “\(item.displayLabel)”: \(error.localizedDescription)"
            }
        }

        let itemIDs = Set(items.map(\.id))
        for (id, record) in state.records where !itemIDs.contains(id) {
            cancel(record.systemIDs)
            state.records[id] = nil
        }
        for alarm in systemAlarms where !keep.contains(alarm.id) {
            try? manager.cancel(id: alarm.id)
        }
        removeUnusedClips()
        save()
    }

    static func specs(for item: AlarmItem, excluding extra: [Date], now: Date, calendar: Calendar = .current) -> [Spec] {
        guard item.isRepeating else {
            return item.nextOccurrence(after: now, excluding: extra).map { [.fixed($0)] } ?? []
        }
        let excluded = (extra + [item.skippedOccurrence].compactMap { $0 }).filter { $0 > now.addingTimeInterval(-90) }
        var days = item.repeatDays
        var oneOffs: [Spec] = []
        for date in excluded {
            let weekday = calendar.component(.weekday, from: date)
            guard days.remove(weekday) != nil,
                  let weekLater = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: date)) else { continue }
            let following = AlarmItem.nextDate(hour: item.hour, minute: item.minute,
                                               after: weekLater.addingTimeInterval(-1), calendar: calendar)
            oneOffs.append(.fixed(following))
        }
        let weekly: [Spec] = days.isEmpty ? [] : [.weekly(hour: item.hour, minute: item.minute, days: days.sorted())]
        return weekly + oneOffs
    }

    // MARK: - Full-song mode hand-off

    func suppress(itemID: UUID, occurrence: Date) {
        state.suppressions[itemID] = occurrence
        save()
    }

    var hasExpiredSuppressions: Bool {
        state.suppressions.values.contains { $0 < Date().addingTimeInterval(-90) }
    }

    func suppressedOccurrences(for itemID: UUID) -> [Date] {
        [state.suppressions[itemID]].compactMap { $0 }
    }

    func scheduleBackup(for item: AlarmItem, at date: Date, library: SoundLibrary) async {
        cancelBackup(for: item.id)
        guard manager.authorizationState == .authorized else { return }
        let clip = clipPlan(for: item, library: library)
        do {
            let soundName = try await prepareClip(clip.name, item: item, sound: clip.sound, library: library)
            let id = UUID()
            _ = try await manager.schedule(id: id, configuration: configuration(
                for: item, systemID: id, schedule: .fixed(date), soundName: soundName, soundTitle: clip.title, isBackup: true))
            state.backups[item.id] = Extra(systemID: id, clipName: soundName, created: .now)
            save()
        } catch {
            lastError = "Couldn't schedule the safety alarm: \(error.localizedDescription)"
        }
    }

    func cancelBackup(for itemID: UUID) {
        guard let backup = state.backups.removeValue(forKey: itemID) else { return }
        try? manager.cancel(id: backup.systemID)
        save()
    }

    func itemID(forBackup systemID: UUID) -> UUID? {
        state.backups.first { $0.value.systemID == systemID }?.key
    }

    /// Called when a system alarm was stopped; forgets one-shot bookkeeping for it.
    func systemAlarmStopped(_ systemID: UUID) {
        if let itemID = itemID(forBackup: systemID) { state.backups[itemID] = nil }
        state.tests[systemID] = nil
        save()
    }

    // MARK: - Test & cancel

    func scheduleTest(for item: AlarmItem, library: SoundLibrary, in seconds: TimeInterval = 10) async throws {
        if manager.authorizationState != .authorized {
            guard await requestAuthorization() == .authorized else { throw CocoaError(.userCancelled) }
        }
        let clip = clipPlan(for: item, library: library)
        let soundName = try await prepareClip(clip.name, item: item, sound: clip.sound, library: library)
        let id = UUID()
        var test = item
        test.label = "Test · \(item.displayLabel)"
        _ = try await manager.schedule(id: id, configuration: configuration(
            for: test, systemID: id, schedule: .fixed(.now.addingTimeInterval(seconds)), soundName: soundName,
            soundTitle: clip.title, isTest: true))
        state.tests[id] = Extra(systemID: id, clipName: soundName, created: .now)
        save()
    }

    /// Cancels everything for an alarm, including a ring or snooze in progress.
    func cancelAll(for itemID: UUID) {
        if let record = state.records.removeValue(forKey: itemID) { cancel(record.systemIDs) }
        cancelBackup(for: itemID)
        save()
    }

    /// App alarms whose system alarm is ringing, snoozed or paused right now.
    func activeItemIDs() -> Set<UUID> {
        let active = Set(systemAlarms.filter { $0.state != .scheduled }.map(\.id))
        let fromRecords = state.records.filter { !active.isDisjoint(with: $0.value.systemIDs) }.keys
        let fromBackups = state.backups.filter { active.contains($0.value.systemID) }.keys
        return Set(fromRecords).union(fromBackups)
    }

    // MARK: - Helpers

    private func configuration(
        for item: AlarmItem, systemID: UUID, schedule: Alarm.Schedule, soundName: String?, soundTitle: String,
        isBackup: Bool = false, isTest: Bool = false
    ) -> AlarmManager.AlarmConfiguration<GoodAlarmMetadata> {
        let snooze = item.snoozeEnabled
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: item.displayLabel),
            secondaryButton: snooze ? AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz") : nil,
            secondaryButtonBehavior: snooze ? .countdown : nil
        )
        let presentation = AlarmPresentation(
            alert: alert,
            countdown: snooze ? .init(title: LocalizedStringResource(stringLiteral: "Snoozing · \(item.displayLabel)")) : nil
        )
        let attributes = AlarmAttributes(
            presentation: presentation,
            metadata: GoodAlarmMetadata(label: item.displayLabel, soundName: soundTitle, isBackup: isBackup),
            tintColor: Color.gaAccent
        )
        return AlarmManager.AlarmConfiguration(
            countdownDuration: snooze ? .init(preAlert: nil, postAlert: TimeInterval(item.snoozeMinutes * 60)) : nil,
            schedule: schedule,
            attributes: attributes,
            stopIntent: StopAlarmIntent(systemID: systemID, itemID: isTest ? nil : item.id),
            secondaryIntent: snooze ? SnoozeAlarmIntent(systemID: systemID) : nil,
            sound: soundName.map { .named($0) } ?? .default
        )
    }

    /// What AlarmKit should play. AlarmKit always vibrates using the device's alarm haptics,
    /// so "vibrate only" is a silent clip.
    private func clipPlan(for item: AlarmItem, library: SoundLibrary) -> (name: String?, title: String, sound: SoundItem) {
        let sound = library.sound(withID: item.soundID)
        if item.isVibrateOnly {
            return (ClipRenderer.silentClipName, "Vibrate only", sound)
        }
        return (sound.isFileBased ? ClipRenderer.clipName(for: item, sound: sound) : nil, sound.name, sound)
    }

    /// Renders the clip if needed and returns the name to hand to AlarmKit (nil = system sound).
    private func prepareClip(_ clipName: String?, item: AlarmItem, sound: SoundItem, library: SoundLibrary) async throws -> String? {
        guard let clipName else { return nil }
        let destination = AppPaths.systemSounds.appending(path: clipName)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return clipName }
        if clipName == ClipRenderer.silentClipName {
            try ClipRenderer.writeSilence(to: destination, seconds: 5)
        } else if let source = library.fileURL(for: sound) {
            try await ClipRenderer.render(source: source, to: destination, startOffset: item.startOffset,
                                          volume: item.volume, fadeIn: item.fadeInSeconds)
        } else {
            return nil
        }
        return clipName
    }

    private func cancel(_ ids: [UUID]) {
        for id in ids { try? manager.cancel(id: id) }
    }

    private func removeUnusedClips() {
        let used = Set(state.records.values.compactMap(\.clipName))
            .union(state.backups.values.compactMap(\.clipName))
            .union(state.tests.values.compactMap(\.clipName))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: AppPaths.systemSounds.path)) ?? []
        for file in files where file.hasPrefix("ga-") && !used.contains(file) {
            try? FileManager.default.removeItem(at: AppPaths.systemSounds.appending(path: file))
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }
}
