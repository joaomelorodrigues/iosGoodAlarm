import AlarmKit
import SwiftUI

/// Extra data attached to every system alarm. Compiled into both the app and the widget
/// extension so the Live Activity can decode `AlarmAttributes<GoodAlarmMetadata>`.
nonisolated struct GoodAlarmMetadata: AlarmMetadata {
    var label: String
    var soundName: String
    var isBackup: Bool
}

extension Color {
    static let gaAccent = Color(red: 1.0, green: 0.48, blue: 0.24)
}
