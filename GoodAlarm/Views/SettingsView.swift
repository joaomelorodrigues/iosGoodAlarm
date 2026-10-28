import SwiftUI

struct SettingsView: View {
    @Environment(AlarmStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage(AppSettings.fullSongModeKey) private var fullSongMode = true
    @AppStorage(AppSettings.overrideSystemVolumeKey) private var overrideSystemVolume = true
    @AppStorage(AppSettings.safetyDelayMinutesKey) private var safetyDelayMinutes = 3

    var body: some View {
        NavigationStack {
            Form {
                Section("Permissions") {
                    LabeledContent("System alarms", value: authorizationText)
                    switch store.authorization {
                    case .notDetermined:
                        Button("Allow alarms") { Task { await store.requestAuthorization() } }
                    case .denied:
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    default:
                        EmptyView()
                    }
                }

                Section {
                    Toggle("Full-song mode", isOn: $fullSongMode)
                    if fullSongMode {
                        Toggle("Set phone volume while ringing", isOn: $overrideSystemVolume)
                        Picker("Safety alarm after", selection: $safetyDelayMinutes) {
                            ForEach([1, 2, 3, 5, 10], id: \.self) { Text("\($0) min").tag($0) }
                        }
                    }
                } header: {
                    Text("Full-song mode")
                } footer: {
                    Text("When Good Alarm is left in the app switcher (don't swipe it away), it plays the whole song, sets the phone to your chosen volume, and fades in over as long as you like. A system safety alarm still rings after the delay above if you haven't stopped it. Uses a little battery overnight.")
                }

                Section("How Good Alarm rings") {
                    InfoRow(icon: "lock.iphone", title: "Always: system alarm",
                            text: "Rings through silent mode, Focus and a closed app, with your song, volume and fade mixed into a 29-second clip that loops.")
                    InfoRow(icon: "music.note.house", title: "When the app is running: full song",
                            text: "Plays the entire track at the exact phone volume you picked, with fades of up to 5 minutes.")
                }

                Section("What Apple still doesn't allow") {
                    InfoRow(icon: "lock.shield", title: "Apple Music streaming songs",
                            text: "They're DRM-protected. Songs you bought or synced, and your own files, work.")
                    InfoRow(icon: "speaker.wave.2", title: "Volume when the app is closed",
                            text: "The system alarm follows your ringer volume, so your volume setting is applied on top of it.")
                    InfoRow(icon: "xmark.app", title: "Force-quitting",
                            text: "Swiping the app away turns off full-song mode until you open it again. The system alarm still rings.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { dismiss() }
                }
            }
        }
    }

    private var authorizationText: String {
        switch store.authorization {
        case .authorized: "Allowed"
        case .denied: "Blocked"
        case .notDetermined: "Not asked yet"
        @unknown default: "Unknown"
        }
    }
}

private struct InfoRow: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
