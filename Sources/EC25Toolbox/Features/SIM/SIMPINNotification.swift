import Foundation
import UserNotifications

/// Posts a single local alert when the modem is healthy but the SIM still needs its PIN.
enum SIMPINNotification {
    static func postLockedSIMNotice() {
        let title = localized("sim_pin.notification.title")
        let body = localized("sim_pin.notification.body")

        Task {
            let center = UNUserNotificationCenter.current()
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else { return }

                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default

                let request = UNNotificationRequest(
                    identifier: "ing.fuyaoskyrocket.ec25toolbox.sim-pin-required",
                    content: content,
                    trigger: nil
                )
                try await center.add(request)
            } catch {
                // Notification permission or delivery failure must not affect modem operation.
            }
        }
    }
}
