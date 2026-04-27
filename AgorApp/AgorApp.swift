import SwiftUI

@main
struct AgorApp: App {
    @State private var appViewModel = AppViewModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // NotificationManager.shared sets itself as delegate in its init
        _ = NotificationManager.shared
        // Register background task before app finishes launching
        BackgroundSessionPoller.shared.registerBackgroundTask()
        // Install MetricKit subscriber + uncaught exception handler
        _ = CrashLogService.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appViewModel: appViewModel)
                .preferredColorScheme(nil)
                .task {
                    await NotificationManager.shared.requestPermission()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background:
                        NotificationManager.shared.isBackgrounded = true
                        BackgroundSessionPoller.shared.scheduleNextPoll()
                    case .active:
                        NotificationManager.shared.isBackgrounded = false
                    default:
                        break
                    }
                }
        }
    }
}
