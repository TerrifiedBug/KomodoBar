import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = KomodoStore.shared
    private var statusController: StatusItemController?
    private let updater: any UpdaterProviding = makeUpdater()

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon — menu-bar only
        self.statusController = StatusItemController(store: self.store, updater: self.updater)
        self.updater.start()
        self.store.start()

        // Headless verification: open Settings on launch when asked.
        if ProcessInfo.processInfo.environment["KOMODOBAR_OPEN_SETTINGS"] != nil {
            self.statusController?.showSettings()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }
}
