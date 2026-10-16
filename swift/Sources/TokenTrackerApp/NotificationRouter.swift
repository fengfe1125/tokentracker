import Foundation
import UserNotifications

/// UNUserNotificationCenter has one delegate for the entire application.
@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()
    private var started = false
    var onRisk: ((String) -> Void)?
    var onTask: ((String) -> Void)?
    func route(task: String?, risk: String?) {
        if let task { onTask?(task) } else if let risk { onRisk?(risk) }
    }
    func start() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = self
        started = true
    }
    func task(id: String, title: String, body: String, sound: Bool) {
        guard started else { return }
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body
        content.userInfo = ["task": id]
        if sound { content.sound = .default }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "task:" + id, content: content, trigger: nil))
    }
    func removeTask(_ id: String) {
        guard started else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["task:" + id])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["task:" + id])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let task = info["task"] as? String; let risk = info["route"] as? String
        Task { @MainActor in
            self.route(task: task, risk: risk)
        }
        completionHandler()
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Use the request's sound selection, including silent task notifications.
        completionHandler(notification.request.content.sound == nil ? [.banner] : [.banner, .sound])
    }
}
