import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = KomodoStore.shared
    private var statusController: StatusItemController?
    private let updater: any UpdaterProviding = makeUpdater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // no Dock icon — menu-bar only
        statusController = StatusItemController(store: store, updater: updater)
        updater.start()
        store.start()

        // Headless verification: open Settings on launch when asked.
        if ProcessInfo.processInfo.environment["KOMODOBAR_OPEN_SETTINGS"] != nil {
            statusController?.showSettings()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
