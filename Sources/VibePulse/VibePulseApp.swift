import AppKit
import SwiftUI

@main
struct VibePulseApp: App {
  @StateObject private var model = AppModel()

  init() {
    NSApplication.shared.setActivationPolicy(.accessory)
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContentView()
        .environmentObject(model)
    } label: {
      MenuBarLabelView(totalText: model.menuTotalText)
    }
    .menuBarExtraStyle(.window)
    .windowResizability(.contentSize)

  }
}
