import SwiftUI

enum TimeFormat {
    static var uses12Hour: Bool {
        DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current)?.contains("a") ?? false
    }

    static func parts(hour: Int, minute: Int) -> (time: String, period: String?) {
        guard uses12Hour else { return (String(format: "%02d:%02d", hour, minute), nil) }
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        let calendar = Calendar.current
        return (String(format: "%d:%02d", displayHour, minute), hour < 12 ? calendar.amSymbol : calendar.pmSymbol)
    }

    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "7 h 32 min"
    static func relative(to date: Date, from now: Date = .now) -> String {
        let minutes = max(0, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
        let days = minutes / 1440, hours = minutes % 1440 / 60, mins = minutes % 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days) d") }
        if hours > 0 { parts.append("\(hours) h") }
        if mins > 0 && days == 0 { parts.append("\(mins) min") }
        return parts.isEmpty ? "less than a minute" : parts.joined(separator: " ")
    }

    /// "Tomorrow", "Thursday", "Thu 5 Nov". Pass `midSentence` for "tomorrow".
    static func day(_ date: Date, midSentence: Bool = false) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return midSentence ? "today" : "Today" }
        if calendar.isDateInTomorrow(date) { return midSentence ? "tomorrow" : "Tomorrow" }
        if date.timeIntervalSinceNow < 6 * 86_400 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "1:23"
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct TimeText: View {
    let hour: Int
    let minute: Int
    var size: CGFloat = 44

    var body: some View {
        let parts = TimeFormat.parts(hour: hour, minute: minute)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(parts.time)
                .font(.system(size: size, weight: .light, design: .rounded))
                .monospacedDigit()
            if let period = parts.period {
                Text(period)
                    .font(.system(size: size * 0.4, weight: .medium, design: .rounded))
            }
        }
    }
}

/// Android-style row of weekday circles.
struct DayChips: View {
    @Binding var days: Set<Int>

    var body: some View {
        let calendar = Calendar.current
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(AlarmItem.orderedWeekdays(calendar), id: \.self) { day in
                    chip(day, isOn: days.contains(day), calendar: calendar)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: days)
    }

    @ViewBuilder
    private func chip(_ day: Int, isOn: Bool, calendar: Calendar) -> some View {
        let button = Button {
            if isOn { days.remove(day) } else { days.insert(day) }
        } label: {
            Text(calendar.veryShortStandaloneWeekdaySymbols[day - 1])
                .font(.subheadline.weight(.semibold))
                .frame(width: 22, height: 22)
        }
        .buttonBorderShape(.circle)
        .accessibilityLabel(calendar.weekdaySymbols[day - 1])
        .accessibilityAddTraits(isOn ? .isSelected : [])

        if isOn {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        Text(toast.message)
            .font(.subheadline.weight(.medium))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension View {
    /// Shows the store's toast at the bottom and clears it after a few seconds.
    func toastOverlay(_ toast: Binding<Toast?>, bottomPadding: CGFloat = 24) -> some View {
        overlay(alignment: .bottom) {
            if let current = toast.wrappedValue {
                ToastView(toast: current)
                    .padding(.bottom, bottomPadding)
                    .task(id: current.id) {
                        try? await Task.sleep(for: .seconds(3.5))
                        if toast.wrappedValue?.id == current.id {
                            withAnimation { toast.wrappedValue = nil }
                        }
                    }
            }
        }
        .animation(.spring(duration: 0.35), value: toast.wrappedValue)
    }
}
