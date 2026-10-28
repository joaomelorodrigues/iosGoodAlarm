import SwiftUI

enum EditorTarget: Identifiable {
    case new(AlarmItem)
    case edit(AlarmItem)

    var id: UUID {
        switch self {
        case .new(let item), .edit(let item): item.id
        }
    }

    /// Where the sheet zooms out from.
    var transitionSource: String {
        switch self {
        case .new: "new"
        case .edit(let item): item.id.uuidString
        }
    }
}

struct AlarmListView: View {
    @Environment(AlarmStore.self) private var store
    @Environment(RingEngine.self) private var engine
    @State private var editing: EditorTarget?
    @State private var showSettings = false
    @Namespace private var transition

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                List {
                    if store.authorization == .denied {
                        PermissionBanner()
                    }
                    if let error = store.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    UpcomingSection(now: context.date)
                    alarmsSection
                }
                .navigationSubtitle(subtitle(now: context.date))
            }
            .overlay {
                if store.alarms.isEmpty {
                    ContentUnavailableView("No alarms", systemImage: "alarm",
                                           description: Text("Tap + to wake up to any song you like."))
                }
            }
            .navigationTitle("Alarms")
            .toolbar { toolbar }
            .sheet(item: $editing) { target in
                AlarmEditorView(target: target)
                    .navigationTransition(.zoom(sourceID: target.transitionSource, in: transition))
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .presentationDetents([.medium, .large])
                    .navigationTransition(.zoom(sourceID: "settings", in: transition))
            }
            .toastOverlay($store.toast, bottomPadding: 72)
        }
    }

    private var alarmsSection: some View {
        Section {
            ForEach(store.alarms) { item in
                AlarmRowView(item: item) { editing = .edit(item) }
                    .matchedTransitionSource(id: item.id.uuidString, in: transition)
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) { store.delete(item.id) }
                    }
                    .swipeActions(edge: .leading) {
                        if item.isEnabled {
                            Button(item.hasActiveSkip ? "Unskip" : "Skip", systemImage: "forward.end") {
                                store.toggleSkipNext(item.id)
                            }
                            .tint(.indigo)
                        }
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editing = .edit(item) }
                        Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicate(item.id) }
                        if item.isEnabled && item.isRepeating {
                            Button(item.hasActiveSkip ? "Undo skip" : "Skip next alarm", systemImage: "forward.end") {
                                store.toggleSkipNext(item.id)
                            }
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { store.delete(item.id) }
                    }
            }
        } footer: {
            if engine.isKeepingAlive {
                Label("Full-song mode is on. Leave Good Alarm in the app switcher overnight.", systemImage: "music.note.house")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Settings", systemImage: "gearshape") { showSettings = true }
        }
        .matchedTransitionSource(id: "settings", in: transition)

        ToolbarItem(placement: .bottomBar) {
            Menu {
                Section("Quick alarm") {
                    ForEach([10, 20, 30, 60], id: \.self) { minutes in
                        Button(minutes < 60 ? "In \(minutes) minutes" : "In 1 hour", systemImage: "timer") {
                            store.addNap(minutes: minutes)
                        }
                    }
                }
            } label: {
                Label("Quick alarm", systemImage: "timer")
            }
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button("Add alarm", systemImage: "plus") { editing = .new(.new()) }
                .buttonStyle(.glassProminent)
        }
        .matchedTransitionSource(id: "new", in: transition)
    }

    private func subtitle(now: Date) -> String {
        if let snooze = engine.snooze {
            return "Snoozed until \(TimeFormat.clock(snooze.until))"
        }
        guard let next = store.nextAlarm else { return store.alarms.isEmpty ? "" : "No alarms on" }
        return "Next in \(TimeFormat.relative(to: next.date, from: now)) · \(TimeFormat.day(next.date)) \(TimeFormat.clock(next.date))"
    }
}

/// Google Clock's "upcoming alarm" card: lets you skip or dismiss the next ring early.
private struct UpcomingSection: View {
    @Environment(AlarmStore.self) private var store
    @Environment(RingEngine.self) private var engine
    let now: Date

    var body: some View {
        if let snooze = engine.snooze, let item = store.alarm(withID: snooze.itemID) {
            Section("Snoozed") {
                row(title: "Rings again at \(TimeFormat.clock(snooze.until))", detail: item.displayLabel,
                    action: "Stop", systemImage: "stop.fill") { engine.endSnooze() }
            }
        } else if let next = store.nextAlarm, next.date.timeIntervalSince(now) < 12 * 3600 {
            Section("Upcoming") {
                row(title: "\(TimeFormat.day(next.date)) \(TimeFormat.clock(next.date))", detail: next.item.displayLabel,
                    action: next.item.isRepeating ? "Skip" : "Dismiss", systemImage: "forward.end") {
                    store.toggleSkipNext(next.item.id)
                }
            }
        }
    }

    private func row(title: String, detail: String, action: String, systemImage: String,
                     perform: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action, systemImage: systemImage, action: perform)
                .buttonStyle(.glass)
        }
    }
}

private struct PermissionBanner: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Alarms are blocked", systemImage: "alarm.waves.left.and.right")
                .font(.headline)
            Text("Without alarm access, iOS won't ring when the app is closed or the phone is on silent.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.glassProminent)
        }
        .padding(.vertical, 4)
    }
}
