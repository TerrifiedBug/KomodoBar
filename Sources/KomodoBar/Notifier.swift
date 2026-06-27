import Foundation
import UserNotifications

/// Abstracts macOS user notifications so dev/headless builds (no app bundle) can
/// use a no-op, mirroring `UpdaterProviding`.
@MainActor
protocol NotifierProviding {
    func requestAuthorization()
    func notify(id: String, title: String, body: String, critical: Bool)
}

/// No-op notifier for contexts without a bundle (CLI, tests, some dev runs).
@MainActor
final class DisabledNotifier: NotifierProviding {
    func requestAuthorization() {}
    func notify(id _: String, title _: String, body _: String, critical _: Bool) {}
}

/// Real notifier over `UNUserNotificationCenter`.
@MainActor
final class UserNotifier: NotifierProviding {
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() {
        self.center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(id: String, title: String, body: String, critical: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // time-sensitive surfaces through Focus when the user has granted it; without
        // the entitlement it degrades gracefully to a normal banner.
        content.interruptionLevel = critical ? .timeSensitive : .active
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        self.center.add(request)
    }
}

/// `UNUserNotificationCenter.current()` traps without an app bundle, so fall back
/// to the no-op notifier when there isn't one (CLI / bare-executable runs).
@MainActor
func makeNotifier() -> any NotifierProviding {
    Bundle.main.bundleIdentifier != nil ? UserNotifier() : DisabledNotifier()
}
