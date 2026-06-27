import AppKit
import SwiftUI

/// Owns the Settings window directly instead of relying on SwiftUI's `Settings`
/// scene + `showSettingsWindow:`, which does not reliably open from an
/// `.accessory` (LSUIElement) menu-bar app — there's no key window for the
/// responder-chain action to land on.
///
/// While the window is open we flip the app to `.regular` so it can take focus
/// and appear in the window list, then back to `.accessory` on close.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: hosting)
            window.title = "KomodoBar Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()

        // Verification hook: confirms the window actually became visible.
        fputs("KomodoBar.settings: visible=\(window?.isVisible == true)\n", stderr)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
