import SwiftUI

@main
struct AgorApp: App {
    @State private var appViewModel = AppViewModel()

    init() {
        // NotificationManager.shared sets itself as delegate in its init
        _ = NotificationManager.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appViewModel: appViewModel)
                .preferredColorScheme(nil)
                .task {
                    await NotificationManager.shared.requestPermission()
                }
        }
    }
}
