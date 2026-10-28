import AVFoundation
import MediaPlayer
import SwiftUI

/// iOS has no public API to set the output volume. The long-standing workaround, used by
/// most alarm apps, is to drive the slider inside an MPVolumeView that lives in the window.
enum SystemVolume {
    private static weak var volumeView: MPVolumeView?

    static var current: Float { AVAudioSession.sharedInstance().outputVolume }

    static func set(_ value: Float) {
        guard let slider = volumeView?.subviews.lazy.compactMap({ $0 as? UISlider }).first else { return }
        slider.setValue(max(0, min(1, value)), animated: false)
        slider.sendActions(for: .valueChanged)
    }

    fileprivate static func register(_ view: MPVolumeView) { volumeView = view }
}

/// Invisible host for the MPVolumeView. Also keeps the system volume HUD from popping up.
struct HiddenVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.alpha = 0.001
        view.isUserInteractionEnabled = false
        SystemVolume.register(view)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
