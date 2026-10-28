import ActivityKit
import AlarmKit
import SwiftUI
import WidgetKit

/// AlarmKit shows this on the Lock Screen and Dynamic Island while an alarm is snoozed.
struct AlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<GoodAlarmMetadata>.self) { context in
            HStack(spacing: 14) {
                Image(systemName: icon(for: context.state.mode))
                    .font(.title)
                    .foregroundStyle(context.attributes.tintColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.metadata?.label ?? "Alarm")
                        .font(.headline)
                    Text(status(for: context.state.mode))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                RemainingText(mode: context.state.mode)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(context.attributes.tintColor)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.metadata?.label ?? "Alarm", systemImage: icon(for: context.state.mode))
                        .font(.headline)
                        .foregroundStyle(context.attributes.tintColor)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RemainingText(mode: context.state.mode)
                        .font(.title2.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(status(for: context.state.mode))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: icon(for: context.state.mode))
                    .foregroundStyle(context.attributes.tintColor)
            } compactTrailing: {
                RemainingText(mode: context.state.mode)
                    .frame(maxWidth: 56)
            } minimal: {
                Image(systemName: icon(for: context.state.mode))
                    .foregroundStyle(context.attributes.tintColor)
            }
            .keylineTint(context.attributes.tintColor)
        }
    }

    private func icon(for mode: AlarmPresentationState.Mode) -> String {
        switch mode {
        case .countdown: "zzz"
        case .paused: "pause.fill"
        default: "alarm.fill"
        }
    }

    private func status(for mode: AlarmPresentationState.Mode) -> String {
        switch mode {
        case .countdown(let countdown): "Snoozed · rings at \(countdown.fireDate.formatted(date: .omitted, time: .shortened))"
        case .paused: "Paused"
        default: "Ringing"
        }
    }
}

private struct RemainingText: View {
    let mode: AlarmPresentationState.Mode

    var body: some View {
        switch mode {
        case .countdown(let countdown):
            Text(timerInterval: Date.now...max(countdown.fireDate, .now), countsDown: true)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        case .paused(let paused):
            let remaining = paused.totalCountdownDuration - paused.previouslyElapsedDuration
            Text(Duration.seconds(remaining), format: .time(pattern: .minuteSecond))
                .monospacedDigit()
        default:
            Text("Now")
        }
    }
}
