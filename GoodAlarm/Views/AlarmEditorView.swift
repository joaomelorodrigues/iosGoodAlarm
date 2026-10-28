import SwiftUI

struct AlarmEditorView: View {
    @Environment(AlarmStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.fullSongModeKey) private var fullSongMode = true

    @State private var draft: AlarmItem
    @State private var skipNext: Bool
    @State private var preview = FadingPlayer()
    @State private var vibrationPreview = Vibrator()
    @State private var isTesting = false
    private let isNew: Bool

    init(target: EditorTarget) {
        switch target {
        case .new(let item):
            _draft = State(initialValue: item)
            _skipNext = State(initialValue: false)
            isNew = true
        case .edit(let item):
            _draft = State(initialValue: item)
            _skipNext = State(initialValue: item.hasActiveSkip)
            isNew = false
        }
    }

    private var sound: SoundItem { store.library.sound(withID: draft.soundID) }

    var body: some View {
        NavigationStack {
            Form {
                timeSection
                repeatSection
                Section {
                    TextField("Label", text: $draft.label, prompt: Text("Label (e.g. Gym)"))
                }
                soundSection
                if !draft.isVibrateOnly {
                    volumeSection
                    fadeSection
                }
                vibrationSection
                snoozeSection
                optionsSection
                testSection
                if !isNew {
                    Section {
                        Button("Delete alarm", role: .destructive) {
                            store.delete(draft.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New alarm" : "Edit alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) {
                        store.save(draft, skipNext: skipNext && draft.isRepeating)
                        dismiss()
                    }
                }
            }
            .onChange(of: draft.soundID) {
                draft.startOffset = 0
                preview.stop()
            }
            .onChange(of: draft.vibrationPattern) {
                vibrationPreview.start(draft.vibrationPattern, duration: 4)
            }
            .onDisappear {
                preview.stop()
                vibrationPreview.stop()
            }
            .toastOverlay(Bindable(store).toast)
        }
    }

    // MARK: - Sections

    private var timeSection: some View {
        Section {
            DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(ringsInText(now: context.date))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var repeatSection: some View {
        Section {
            DayChips(days: $draft.repeatDays)
                .padding(.vertical, 4)
            Picker("Preset", selection: presetBinding) {
                Text("Once").tag(Set<Int>?.some([]))
                Text("Weekdays").tag(Set<Int>?.some([2, 3, 4, 5, 6]))
                Text("Weekends").tag(Set<Int>?.some([1, 7]))
                Text("Daily").tag(Set<Int>?.some(Set(1...7)))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } header: {
            Text("Repeat")
        }
    }

    /// Nil when the chosen days don't match a preset, so no segment is selected.
    private var presetBinding: Binding<Set<Int>?> {
        let presets: [Set<Int>] = [[], [2, 3, 4, 5, 6], [1, 7], Set(1...7)]
        return Binding(
            get: { presets.contains(draft.repeatDays) ? draft.repeatDays : nil },
            set: { if let days = $0 { draft.repeatDays = days } }
        )
    }

    private var soundSection: some View {
        Section {
            if Haptics.isSupported {
                Toggle("Play sound", isOn: Binding(
                    get: { draft.soundEnabled },
                    set: { enabled in
                        draft.soundEnabled = enabled
                        if !enabled {
                            draft.vibrate = true
                            preview.stop()
                        }
                    }
                ))
            }
            if !draft.isVibrateOnly {
                NavigationLink {
                    SoundPickerView(selection: $draft.soundID)
                } label: {
                    LabeledContent("Sound") {
                        Text(sound.name).lineLimit(1)
                    }
                }
                if sound.isFileBased && sound.duration > 10 {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Start at", value: "\(TimeFormat.duration(draft.startOffset)) / \(TimeFormat.duration(sound.duration))")
                        Slider(value: $draft.startOffset, in: 0...max(1, sound.duration - 5), step: 1)
                    }
                }
                if sound.isFileBased {
                    Button {
                        togglePreview()
                    } label: {
                        Label(preview.isPlaying ? "Stop preview" : "Preview with volume and fade",
                              systemImage: preview.isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    }
                }
            }
        } header: {
            Text("Sound")
        } footer: {
            if draft.isVibrateOnly {
                Text("Vibrate only. The system alarm rings silently and the iPhone vibrates, even if Good Alarm is closed.")
            } else if !sound.isFileBased {
                Text("The iPhone sound can't be previewed, faded or volume-adjusted. Pick another sound for those.")
            } else if sound.duration > 10 {
                Text("Start at the chorus, not the quiet intro.")
            }
        }
    }

    private var volumeSection: some View {
        Section {
            HStack {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $draft.volume, in: 0.05...1)
                    .onChange(of: draft.volume) { preview.setAmplitude(ClipRenderer.amplitude(forVolume: draft.volume)) }
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                Text("\(Int((draft.volume * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            .disabled(!sound.isFileBased)
        } header: {
            Text("Alarm volume")
        } footer: {
            Text(fullSongMode
                 ? "In full-song mode the phone is set to this volume while ringing. When the system alarm rings instead (app closed), it plays at this level relative to your ringer volume."
                 : "Plays at this level relative to your ringer volume.")
        }
    }

    private var fadeSection: some View {
        Section {
            Picker("Gradually increase volume", selection: $draft.fadeInSeconds) {
                ForEach(FadeOption.all, id: \.self) { Text(FadeOption.label($0)).tag($0) }
            }
            .disabled(!sound.isFileBased)
        } footer: {
            if draft.fadeInSeconds > ClipRenderer.maxBakedFade {
                Text(fullSongMode
                     ? "Fades longer than \(Int(ClipRenderer.maxBakedFade)) s need full-song mode. If the app was closed, the system alarm fades in over \(Int(ClipRenderer.maxBakedFade)) s instead."
                     : "Without full-song mode the system alarm fades in over \(Int(ClipRenderer.maxBakedFade)) s at most. Turn on full-song mode in Settings for longer fades.")
            }
        }
    }

    private var vibrationSection: some View {
        Section {
            if Haptics.isSupported {
                Toggle("Vibrate", isOn: $draft.vibrate)
                    .disabled(draft.isVibrateOnly)
                if draft.vibrate && !draft.isVibrateOnly {
                    Picker("Pattern", selection: $draft.vibrationPattern) {
                        ForEach(VibrationPattern.allCases) { Text($0.name).tag($0) }
                    }
                    Button {
                        vibrationPreview.start(draft.vibrationPattern, duration: 4)
                    } label: {
                        Label("Feel the pattern", systemImage: "iphone.radiowaves.left.and.right")
                    }
                }
            } else {
                LabeledContent("Vibration", value: "Not available on this device")
            }
        } header: {
            Text("Vibration")
        } footer: {
            if Haptics.isSupported {
                Text(draft.isVibrateOnly
                     ? "Uses the iPhone's own alarm vibration."
                     : "Patterns play when Good Alarm rings in full-song mode. When the system alarm rings instead (app closed), the iPhone uses its own alarm vibration, which apps can't change or turn off.")
            }
        }
    }

    private var snoozeSection: some View {
        Section("Snooze") {
            Toggle("Snooze", isOn: $draft.snoozeEnabled)
            if draft.snoozeEnabled {
                Picker("Snooze length", selection: $draft.snoozeMinutes) {
                    ForEach(SnoozeOption.all, id: \.self) { Text("\($0) min").tag($0) }
                }
            }
        }
    }

    private var optionsSection: some View {
        Section {
            if draft.isRepeating {
                Toggle("Skip next alarm", isOn: $skipNext)
            } else {
                Toggle("Delete after ringing", isOn: $draft.deleteAfterRinging)
            }
        } footer: {
            if draft.isRepeating, skipNext, let next = draft.nextOccurrence(after: .now, excluding: []) {
                Text("Won't ring \(TimeFormat.day(next, midSentence: true)) at \(TimeFormat.clock(next)), then continues as usual.")
            }
        }
    }

    private var testSection: some View {
        Section {
            Button {
                isTesting = true
                preview.stop()
                Task {
                    await store.testSystemAlarm(draft)
                    isTesting = false
                }
            } label: {
                if isTesting {
                    ProgressView()
                } else {
                    Label("Test system alarm in 10 seconds", systemImage: "bell.badge.waveform")
                }
            }
            .disabled(isTesting)
        } footer: {
            Text("Lock the phone and put it on silent to hear exactly what will wake you, even with the app closed.")
        }
    }

    // MARK: - Helpers

    private var timeBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: draft.hour, minute: draft.minute, second: 0, of: .now) ?? .now },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft.hour = parts.hour ?? 0
                draft.minute = parts.minute ?? 0
            }
        )
    }

    private func ringsInText(now: Date) -> String {
        var probe = draft
        probe.skippedOccurrence = nil
        let date = probe.isRepeating
            ? probe.nextOccurrence(after: now)
            : AlarmItem.nextDate(hour: probe.hour, minute: probe.minute, after: now)
        guard let date else { return "" }
        return "Rings \(TimeFormat.day(date, midSentence: true)) · in \(TimeFormat.relative(to: date, from: now))"
    }

    private func togglePreview() {
        if preview.isPlaying {
            preview.stop()
            return
        }
        guard let url = store.library.fileURL(for: sound) else { return }
        FadingPlayer.activatePlaybackSession()
        try? preview.play(url: url, from: draft.startOffset,
                          amplitude: ClipRenderer.amplitude(forVolume: draft.volume),
                          fadeIn: draft.fadeInSeconds)
    }
}
