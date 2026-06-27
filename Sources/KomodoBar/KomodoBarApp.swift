import AppKit
import SwiftUI

@main
@MainActor
struct KomodoBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI needs at least one Scene to keep its lifecycle (and the
        // openSettings action) alive. This is a menu-bar agent app with no real
        // window, so we park a 1x1 keepalive window far offscreen and invisible.
        // Settings is presented via SettingsWindowController (AppKit), not the
        // SwiftUI `Settings` scene, which doesn't open reliably from an
        // `.accessory` menu-bar app.
        WindowGroup("KomodoBarKeepalive") {
            KeepaliveView()
        }
        .windowResizability(.contentSize)
    }
}

private struct KeepaliveView: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                for window in NSApplication.shared.windows where window.title == "KomodoBarKeepalive" {
                    window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
                    window.alphaValue = 0
                    window.ignoresMouseEvents = true
                }
            }
    }
}
