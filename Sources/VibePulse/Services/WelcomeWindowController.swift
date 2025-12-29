import AppKit
import SwiftUI

final class WelcomeWindowController {
    private var window: NSWindow?

    func show(model: AppModel, onContinue: @escaping () -> Void) {
        if window == nil {
            let hostingController = NSHostingController(rootView: WelcomeView {
                onContinue()
                self.window?.close()
            }.environmentObject(model))
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Welcome"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 380, height: 320))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
