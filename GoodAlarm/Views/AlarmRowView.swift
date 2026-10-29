import SwiftUI

struct AlarmRowView: View {
    @Environment(AlarmStore.self) private var store
    @AppStorage(AppSettings.fullSongModeKey) private var fullSongMode = false
    let item: AlarmItem
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 4) {
                    TimeText(hour: item.hour, minute: item.minute)
                    Text(scheduleLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    soundLine
                    if item.hasActiveSkip, let skipped = item.skippedOccurrence {
                        Label("Skipping \(TimeFormat.day(skipped, midSentence: true))", systemImage: "forward.end.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.indigo)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Toggle("Enabled", isOn: Binding(
                get: { item.isEnabled },
                set: { store.setEnabled($0, for: item.id) }
            ))
            .labelsHidden()
        }
        .opacity(item.isEnabled ? 1 : 0.55)
        .padding(.vertical, 4)
    }

    private var scheduleLine: String {
        let when = item.isRepeating ? item.repeatSummary() : item.displayDate().map { TimeFormat.day($0) } ?? ""
        return item.label.isEmpty ? when : "\(item.label) · \(when)"
    }

    private var soundLine: some View {
        let sound = store.library.sound(withID: item.soundID)
        return HStack(spacing: 10) {
            if item.isVibrateOnly {
                Label("Vibrate only", systemImage: "iphone.radiowaves.left.and.right")
            } else {
                Label(sound.name, systemImage: "music.note")
                    .lineLimit(1)
            }
            Group {
                if sound.isFileBased && !item.isVibrateOnly {
                    Label("\(Int((item.volume * 100).rounded()))%", systemImage: "speaker.wave.2.fill")
                    if item.fadeInSeconds > 0 {
                        Label(FadeOption.shortLabel(item.fadeInSeconds), systemImage: "chart.line.uptrend.xyaxis")
                    }
                }
                // Without full-song mode the system alarm rings, and it always vibrates.
                if (item.vibrate || !fullSongMode) && !item.isVibrateOnly && Haptics.isSupported {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .accessibilityLabel("Vibrates")
                }
                if item.snoozeEnabled {
                    Label("\(item.snoozeMinutes) min", systemImage: "zzz")
                }
            }
            .fixedSize()
        }
        .labelStyle(CompactLabelStyle())
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}
