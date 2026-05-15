import SwiftUI

@main
struct LogosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var client = LogosClient()
    @StateObject private var notifications = NotificationCoordinator.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
                .environmentObject(notifications)
        }
    }
}
