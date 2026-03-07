import UserNotifications

struct NotificationManager {

    static func requestPermission() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    static func notify(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil   // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }

    // Convenience: sync failure notification
    static func notifyFailure(_ message: String) {
        notify(
            title: "Kindle Sync failed",
            body: message.isEmpty ? "Click to retry" : message,
            identifier: "com.jeff.kindlesync.failure"
        )
    }

    // Convenience: session expired notification
    static func notifyNeedsAuth() {
        notify(
            title: "Kindle Sync needs re-authentication",
            body: "Click to sign in again.",
            identifier: "com.jeff.kindlesync.needsAuth"
        )
    }

    // Convenience: schedule set notification
    static func notifyScheduleSet(interval: SyncInterval, nextDate: Date) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        notify(
            title: "Kindle Sync scheduled",
            body: "\(interval.displayName) sync enabled. Next: \(formatter.string(from: nextDate))",
            identifier: "com.jeff.kindlesync.scheduleSet"
        )
    }

    // Convenience: schedule cancelled notification
    static func notifyScheduleCancelled() {
        notify(
            title: "Kindle Sync schedule cancelled",
            body: "Auto-sync has been turned off.",
            identifier: "com.jeff.kindlesync.scheduleCancelled"
        )
    }
}
