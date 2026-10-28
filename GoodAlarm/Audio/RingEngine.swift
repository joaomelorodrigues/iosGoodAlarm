import AVFoundation
import MediaPlayer
import Observation
import UserNotifications

/// Full-song mode. While the app is left running (foreground or background), it plays the
/// whole song at a chosen phone volume with fades of any length, which AlarmKit can't do.
///
/// A few seconds before an alarm, the engine takes over: it pulls that occurrence out of
/// AlarmKit and schedules a system "safety" alarm a few minutes later. If the app is killed
/// overnight, nothing was taken over and AlarmKit rings as usual.
@Observable
final class RingEngine {
    static let shared = RingEngine()

    struct Ringing: Identifiable, Equatable {
        let id = UUID()
        let itemID: UUID
        let label: String
        let soundName: String
        let snoozeMinutes: Int?
    }

    struct Snooze: Equatable {
        let itemID: UUID
        let until: Date
    }

    private(set) var ringing: Ringing?
    private(set) var snooze: Snooze?
    private(set) var isKeepingAlive = false

    @ObservationIgnored private let player = FadingPlayer()
    @ObservationIgnored private let vibrator = Vibrator()
    @ObservationIgnored private var silence: AVAudioPlayer?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var pendingTakeover: UUID?
    @ObservationIgnored private var volumeToRestore: Float?
    @ObservationIgnored private var store: AlarmStore { .shared }
    @ObservationIgnored private var library: SoundLibrary { .shared }

    static let notificationCategory = "GA_RINGING"
    static let stopAction = "GA_STOP"
    static let snoozeAction = "GA_SNOOZE"
    private static let notificationID = "ga-ringing"

    func start() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { RingEngine.shared.tick() }
        }
        configureRemoteCommands()
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let ended = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init) == .ended
            MainActor.assumeIsolated { if ended { RingEngine.shared.resumeAfterInterruption() } }
        }
        tick()
    }

    func isBusy(with itemID: UUID) -> Bool {
        ringing?.itemID == itemID || snooze?.itemID == itemID || pendingTakeover == itemID
    }

    // MARK: - Clock

    private func tick() {
        let now = Date()
        if let snooze, ringing == nil, now >= snooze.until {
            self.snooze = nil
            if let item = store.alarm(withID: snooze.itemID) { beginRinging(item) }
        } else if ringing == nil, pendingTakeover == nil, AppSettings.fullSongMode,
                  let (item, date) = nextCandidate(within: 6, now: now) {
            takeOver(item, at: date)
        }
        if store.scheduler.hasExpiredSuppressions {
            Task { await store.sync() }
        }
        updateKeepAlive(now: now)
    }

    private func nextCandidate(within interval: TimeInterval, now: Date) -> (AlarmItem, Date)? {
        store.alarms
            .compactMap { item -> (AlarmItem, Date)? in
                guard item.isEnabled, !item.isVibrateOnly, library.sound(withID: item.soundID).isFileBased,
                      let date = item.nextOccurrence(after: now.addingTimeInterval(-1),
                                                     excluding: store.scheduler.suppressedOccurrences(for: item.id)),
                      date.timeIntervalSince(now) <= interval else { return nil }
                return (item, date)
            }
            .min { $0.1 < $1.1 }
    }

    private func takeOver(_ item: AlarmItem, at date: Date) {
        pendingTakeover = item.id
        store.beginInAppRing(itemID: item.id, occurrence: date)
        Task {
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard pendingTakeover == item.id, let current = store.alarm(withID: item.id), current.isEnabled else {
                pendingTakeover = nil
                return
            }
            beginRinging(current)
        }
    }

    // MARK: - Ringing

    private func beginRinging(_ item: AlarmItem) {
        pendingTakeover = nil
        let sound = library.sound(withID: item.soundID)
        guard let url = library.fileURL(for: sound) else { return }
        stopSilence()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            // Another app holds a non-mixable session; duck it instead of failing.
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .duckOthers])
            try? session.setActive(true)
        }

        var amplitude = ClipRenderer.amplitude(forVolume: item.volume)
        if AppSettings.overrideSystemVolume {
            volumeToRestore = SystemVolume.current
            SystemVolume.set(Float(item.volume))
            amplitude = 1
        }
        do {
            try player.play(url: url, from: item.startOffset, amplitude: amplitude, fadeIn: item.fadeInSeconds)
        } catch {
            // The safety alarm will still go off.
            restoreVolume()
            return
        }
        if item.vibrate { vibrator.start(item.vibrationPattern) }
        ringing = Ringing(itemID: item.id, label: item.displayLabel, soundName: sound.name,
                          snoozeMinutes: item.snoozeEnabled ? item.snoozeMinutes : nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: item.displayLabel,
            MPMediaItemPropertyArtist: "Good Alarm · pause to stop, skip to snooze",
        ]
        postRingingNotification(for: item)
    }

    func snoozeRinging() {
        guard let ringing, let minutes = ringing.snoozeMinutes else { return }
        let until = Date.now.addingTimeInterval(TimeInterval(minutes * 60))
        stopRinging()
        snooze = Snooze(itemID: ringing.itemID, until: until)
        store.inAppRingSnoozed(itemID: ringing.itemID, until: until)
        store.toast = Toast(message: "Snoozed until \(TimeFormat.clock(until))")
        updateKeepAlive(now: .now)
    }

    func dismissRinging() {
        guard let ringing else { return }
        stopRinging()
        store.inAppRingFinished(itemID: ringing.itemID)
        updateKeepAlive(now: .now)
    }

    /// "Stop" on a snoozed alarm: it won't ring again.
    func endSnooze() {
        guard let snooze else { return }
        self.snooze = nil
        store.inAppRingFinished(itemID: snooze.itemID)
        updateKeepAlive(now: .now)
    }

    /// Drops any in-app ring, snooze or pending takeover for this alarm (it was edited,
    /// disabled, or its safety alarm took over).
    func cancel(itemID: UUID) {
        if ringing?.itemID == itemID { stopRinging() }
        if snooze?.itemID == itemID { snooze = nil }
        if pendingTakeover == itemID { pendingTakeover = nil }
        updateKeepAlive(now: .now)
    }

    private func stopRinging() {
        player.stop()
        vibrator.stop()
        restoreVolume()
        ringing = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func restoreVolume() {
        if let volumeToRestore { SystemVolume.set(volumeToRestore) }
        volumeToRestore = nil
    }

    private func resumeAfterInterruption() {
        if ringing != nil {
            try? AVAudioSession.sharedInstance().setActive(true)
            player.resume()
        } else if isKeepingAlive {
            stopSilence()
            updateKeepAlive(now: .now)
        }
    }

    // MARK: - Keep-alive

    /// Plays silence (mixed with other audio) so iOS keeps the app running until the alarm.
    private func updateKeepAlive(now: Date) {
        let needed = AppSettings.fullSongMode && ringing == nil
            && (snooze != nil || pendingTakeover != nil || nextCandidate(within: 24 * 3600, now: now) != nil)
        if needed, silence?.isPlaying != true {
            FadingPlayer.activatePlaybackSession()
            silence = try? AVAudioPlayer(contentsOf: Self.silenceURL)
            silence?.numberOfLoops = -1
            silence?.play()
        } else if !needed, silence != nil {
            stopSilence()
        }
        isKeepingAlive = silence?.isPlaying == true
    }

    private func stopSilence() {
        silence?.stop()
        silence = nil
        isKeepingAlive = false
    }

    private static let silenceURL: URL = {
        let url = URL.cachesDirectory.appending(path: "silence.caf")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? ClipRenderer.writeSilence(to: url, seconds: 1)
        }
        return url
    }()

    // MARK: - Lock screen controls

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.pauseCommand, center.togglePlayPauseCommand, center.stopCommand] {
            command.addTarget { _ in
                MainActor.assumeIsolated { RingEngine.shared.dismissRinging() }
                return .success
            }
        }
        center.nextTrackCommand.addTarget { _ in
            MainActor.assumeIsolated { RingEngine.shared.snoozeRinging() }
            return .success
        }
    }

    private func postRingingNotification(for item: AlarmItem) {
        let content = UNMutableNotificationContent()
        content.title = item.displayLabel
        content.body = "Ringing now. Open Good Alarm or long-press to stop or snooze."
        content.categoryIdentifier = Self.notificationCategory
        content.interruptionLevel = .timeSensitive
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil))
    }

    static func registerNotificationCategory() {
        let stop = UNNotificationAction(identifier: stopAction, title: "Stop", options: [.destructive])
        let snooze = UNNotificationAction(identifier: snoozeAction, title: "Snooze", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: notificationCategory, actions: [stop, snooze], intentIdentifiers: []),
        ])
    }
}
