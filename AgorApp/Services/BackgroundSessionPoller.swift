import BackgroundTasks
import Foundation

final class BackgroundSessionPoller {
    static let shared = BackgroundSessionPoller()
    static let taskIdentifier = "com.agor.AgorApp.session-poll"

    private var client: AgorClient?

    func configure(client: AgorClient) {
        self.client = client
    }

    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else { return }
            self.handleBackgroundPoll(task: appRefreshTask)
        }
        AppLogger.shared.log("[BGPoller] registered background task", level: .info, category: "Background")
    }

    func scheduleNextPoll() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60) // 5 minutes
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLogger.shared.log("[BGPoller] scheduled next poll in ~5min", level: .debug, category: "Background")
        } catch {
            AppLogger.shared.log("[BGPoller] failed to schedule: \(error.localizedDescription)", level: .error, category: "Background")
        }
    }

    private func handleBackgroundPoll(task: BGAppRefreshTask) {
        // Schedule the next poll before doing work
        scheduleNextPoll()

        let pollTask = Task {
            await pollSessionStatuses()
        }

        task.expirationHandler = {
            pollTask.cancel()
        }

        Task {
            await pollTask.value
            task.setTaskCompleted(success: true)
        }
    }

    private func pollSessionStatuses() async {
        guard let client else {
            AppLogger.shared.log("[BGPoller] no client configured", level: .warning, category: "Background")
            return
        }

        do {
            let response: PaginatedResponse<Session> = try await client.getPaginated(
                "/sessions",
                query: [
                    "archived": "false",
                    "$limit": "50",
                    "$sort[last_updated]": "-1",
                ]
            )

            let sessions = response.data
            AppLogger.shared.log("[BGPoller] polled \(sessions.count) sessions", level: .debug, category: "Background")

            // Check for missed transitions and fire notifications
            NotificationManager.shared.checkMissedTransitions(currentSessions: sessions)
        } catch {
            AppLogger.shared.log("[BGPoller] poll failed: \(error.localizedDescription)", level: .error, category: "Background")
        }
    }
}
