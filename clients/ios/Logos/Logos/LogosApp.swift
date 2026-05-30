import SwiftUI

@main
struct LogosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var client = LogosClient()
    @State private var notifications = NotificationCoordinator.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(client)
                .environment(notifications)
        }
    }
}
