import Sparkle

final class UpdaterController: ObservableObject {
  private let controller: SPUStandardUpdaterController

  init() {
    controller = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    if controller.updater.automaticallyChecksForUpdates {
      controller.updater.checkForUpdatesInBackground()
    }
  }

  var canCheckForUpdates: Bool {
    controller.updater.canCheckForUpdates
  }

  func checkForUpdates() {
    controller.checkForUpdates(nil)
  }
}
