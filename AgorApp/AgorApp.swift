import SwiftUI
import UserNotifications

@main
struct AgorApp: App {
    @State private var appViewModel = AppViewModel()

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
