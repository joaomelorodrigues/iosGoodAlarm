import SwiftUI
import UserNotifications

@main
struct GoodAlarmApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = AlarmStore.shared
    @State private var engine = RingEngine.shared

    var body: some Scene {
        WindowGroup {
            AlarmListView()
                .environment(store)
                .environment(engine)
                .background { HiddenVolumeView().frame(width: 1, height: 1) }
                .fullScreenCover(item: Binding(get: { engine.ringing }, set: { _ in })) { ringing in
                    RingingView(ringing: ringing)
                        .environment(engine)
                }
                .task {
                    await store.bootstrap()
                    engine.start()
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                }
                .tint(.gaAccent)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.appBecameActive() }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        RingEngine.registerNotificationCategory()
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case RingEngine.stopAction: RingEngine.shared.dismissRinging()
            case RingEngine.snoozeAction: RingEngine.shared.snoozeRinging()
            default: break
            }
        }
    }

    /// The ringing screen is already up when the app is open; no banner needed.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}
