import AppKit
import SwiftUI

@main
struct VibePulseApp: App {
  @StateObject private var model = AppModel()
  @StateObject private var updaterController = UpdaterController()

  init() {
    NSApplication.shared.setActivationPolicy(.accessory)
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContentView()
        .environmentObject(model)
        .environmentObject(updaterController)
    } label: {
      MenuBarLabelView(totalText: model.menuTotalText)
    }
    .menuBarExtraStyle(.window)
    .windowResizability(.contentSize)

  }
}
