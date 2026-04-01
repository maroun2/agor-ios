import SwiftUI
import UserNotifications

// MARK: - Notification Delegate (enables foreground banners)

class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@main
struct AgorApp: App {
    @State private var appViewModel = AppViewModel()
    private let notificationDelegate = NotificationDelegate()

    init() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appViewModel: appViewModel)
                .preferredColorScheme(nil) // Follow system
                .task {
                    await requestNotificationPermission()
                }
        }
    }

    private func requestNotificationPermission() async {
        do {
            try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // Non-fatal — notifications just won't work
        }
    }
}
