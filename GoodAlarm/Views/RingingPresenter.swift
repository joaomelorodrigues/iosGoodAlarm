import SwiftUI
import UIKit

/// Shows the ringing screen in its own window above everything, including an open sheet
/// (a SwiftUI full-screen cover can't appear while a sheet is up).
final class RingingPresenter {
    static let shared = RingingPresenter()

    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?

    func update(_ ringing: RingEngine.Ringing?) {
        guard let ringing else {
            window?.isHidden = true
            window = nil
            previousKeyWindow?.makeKey()
            return
        }
        let content = AnyView(RingingView(ringing: ringing).environment(RingEngine.shared).tint(.gaAccent))
        if let host = window?.rootViewController as? UIHostingController<AnyView> {
            host.rootView = content
            return
        }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: content)
        window.makeKeyAndVisible()
        self.window = window
    }
}
