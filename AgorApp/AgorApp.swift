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
                    // Re-arm the refresh chain on every launch: if a previous BG task
                    // never fired (or the app was force-quit), the pending request may
                    // be gone — submitting here self-heals the schedule.
                    BackgroundSessionPoller.shared.scheduleNextPoll()
                    // Load Whisper in the background so voice mode starts instantly
                    // instead of downloading/warming the model on first use.
                    TranscriptionService.preload()
                    VoiceActivityDetector.preload()
                    // Drop cached file payloads older than 3 days.
                    Task.detached(priority: .utility) {
                        FileContentCache.prune()
                        MessageCache.prune()
                    }
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
