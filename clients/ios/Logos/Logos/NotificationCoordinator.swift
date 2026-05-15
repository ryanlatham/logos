import Foundation
import UIKit
import UserNotifications

struct LogosNotificationRoute: Equatable {
    let kind: String
    let projectKey: String
    let sessionID: String?
    let messageID: String?
    let requestID: String?
    let serverSeq: Int?

    static func from(userInfo: [AnyHashable: Any]) -> LogosNotificationRoute? {
        guard let projectKey = userInfo["project_key"] as? String else { return nil }
        let seq: Int?
        if let value = userInfo["server_seq"] as? Int {
            seq = value
        } else if let value = userInfo["server_seq"] as? String {
            seq = Int(value)
        } else {
            seq = nil
        }
        return LogosNotificationRoute(
            kind: userInfo["kind"] as? String ?? "finished",
            projectKey: projectKey,
            sessionID: userInfo["session_id"] as? String,
            messageID: userInfo["message_id"] as? String,
            requestID: userInfo["request_id"] as? String,
            serverSeq: seq
        )
    }

    static func from(url: URL) -> LogosNotificationRoute? {
        guard url.scheme == "logos" else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        guard let projectKey = value("project_key") else { return nil }
        return LogosNotificationRoute(
            kind: value("kind") ?? url.host ?? "finished",
            projectKey: projectKey,
            sessionID: value("session_id"),
            messageID: value("message_id"),
            requestID: value("request_id"),
            serverSeq: value("server_seq").flatMap(Int.init)
        )
    }
}

@MainActor
final class NotificationCoordinator: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()

    @Published private(set) var authorizationStatus: String = "Notifications not requested"
    @Published private(set) var deviceToken: String?
    @Published private(set) var lastRoute: LogosNotificationRoute?

    var onRoute: ((LogosNotificationRoute) -> Void)?
    var onDeviceToken: ((String) -> Void)?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorizationAndRegister() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            Task { @MainActor in
                if let error {
                    self.authorizationStatus = "Notification permission failed: \(error.localizedDescription)"
                    return
                }
                self.authorizationStatus = granted ? "Notifications allowed" : "Notifications denied"
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
    }

    func setDeviceToken(_ data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        onDeviceToken?(token)
    }

    func setRegistrationError(_ error: Error) {
        authorizationStatus = "Remote notification registration failed: \(error.localizedDescription)"
    }

    func route(_ route: LogosNotificationRoute) {
        lastRoute = route
        onRoute?(route)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            if let route = LogosNotificationRoute.from(userInfo: userInfo) {
                self.route(route)
            }
            completionHandler()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            NotificationCoordinator.shared.setDeviceToken(deviceToken)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            NotificationCoordinator.shared.setRegistrationError(error)
        }
    }
}
