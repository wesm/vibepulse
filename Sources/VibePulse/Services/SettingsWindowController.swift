import AppKit
import SwiftUI

final class SettingsWindowController {
  private var window: NSWindow?

  func show(model: AppModel) {
    if window == nil {
      let hostingController = NSHostingController(rootView: SettingsView().environmentObject(model))
      let window = NSWindow(contentViewController: hostingController)
      window.title = "Settings"
      window.styleMask = [.titled, .closable, .miniaturizable]
      window.setContentSize(NSSize(width: 480, height: 420))
      window.isReleasedWhenClosed = false
      window.center()
      self.window = window
    }

    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }
}
