import SwiftUI

/// Shown while full-song mode is ringing with the app open.
struct RingingView: View {
    let ringing: RingEngine.Ringing
    @Environment(RingEngine.self) private var engine

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.08, blue: 0.25), Color(red: 0.85, green: 0.38, blue: 0.22),
                                    Color(red: 1.0, green: 0.78, blue: 0.45)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer()
                Image(systemName: "alarm.waves.left.and.right.fill")
                    .font(.system(size: 56))
                    .symbolEffect(.wiggle, options: .repeat(.continuous))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 92, weight: .thin, design: .rounded))
                        .monospacedDigit()
                }
                Text(ringing.label)
                    .font(.title2.weight(.semibold))
                Label(ringing.soundName, systemImage: "music.note")
                    .font(.subheadline)
                    .opacity(0.85)
                Spacer()

                GlassEffectContainer(spacing: 16) {
                    buttons
                }
            }
            .foregroundStyle(.white)
            .padding(24)
        }
        .sensoryFeedback(.warning, trigger: ringing.id)
    }

    private var buttons: some View {
        VStack(spacing: 16) {
            if let minutes = ringing.snoozeMinutes {
                Button {
                    engine.snoozeRinging()
                } label: {
                    Label("Snooze \(minutes) min", systemImage: "zzz")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color(red: 0.32, green: 0.13, blue: 0.08))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.glass)
            }
            Button {
                engine.dismissRinging()
            } label: {
                Text("Stop")
                    .font(.title.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
            .buttonStyle(.glassProminent)
        }
    }
}
