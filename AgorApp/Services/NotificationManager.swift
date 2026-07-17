import Foundation
import UIKit
import UserNotifications

@Observable
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    // Live state — reference semantics, always current
    var previousSessionStatuses: [String: SessionStatus] = [:]
    var activeSessionId: String?
    var isBackgrounded = false
    var favoriteSessionIds: Set<String> = []

    // Track last notified status per session to avoid duplicate notifications
    // Key: sessionId, Value: status we last notified about
    private var lastNotifiedStatus: [String: SessionStatus] = [:]

    // Published when user taps a notification
    var pendingNavigationSessionId: String?

    /// Direct navigation callback — set by MainNavigationView. More reliable than
    /// observation of pendingNavigationSessionId (which stays as cold-launch fallback
    /// for taps that arrive before the view registers this callback).
    var onNavigateToSession: ((String) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            AppLogger.shared.log("[Notification] permission \(granted ? "granted" : "denied")", level: .info, category: "Notification")
        } catch {
            AppLogger.shared.log("[Notification] permission error: \(error.localizedDescription)", level: .error, category: "Notification")
        }
    }

    /// Seed statuses from loaded sessions (call after boards load)
    func seedStatuses(from sessions: [Session]) {
        var count = 0
        for session in sessions {
            if previousSessionStatuses[session.sessionId] == nil {
                previousSessionStatuses[session.sessionId] = session.status
                count += 1
            }
        }
        AppLogger.shared.log("[Notification] seeded \(count) new statuses (total: \(previousSessionStatuses.count))", level: .debug, category: "Notification")
    }

    /// Called when a session patch event arrives via socket
    func handleSessionUpdate(_ session: Session) -> SessionStatusTransition? {
        let previousStatus = previousSessionStatuses[session.sessionId]
        previousSessionStatuses[session.sessionId] = session.status

        let shortId = String(session.sessionId.prefix(8))

        guard let prev = previousStatus, prev != session.status else {
            return nil
        }

        AppLogger.shared.log("[Notification] session \(shortId): \(prev.rawValue) -> \(session.status.rawValue)", level: .debug, category: "Notification")

        // Session started running again — clear notified flag so next idle transition can notify
        if session.status == .running {
            lastNotifiedStatus.removeValue(forKey: session.sessionId)
        }

        return SessionStatusTransition(
            sessionId: session.sessionId,
            previousStatus: prev,
            newStatus: session.status,
            displayTitle: session.displayTitle,
            isScheduled: session.isScheduled
        )
    }

    /// Check if we should fire a local notification for this transition
    func shouldNotify(for transition: SessionStatusTransition) -> Bool {
        // Never notify for scheduled sessions
        if transition.isScheduled {
            AppLogger.shared.log("[Notification] skip \(String(transition.sessionId.prefix(8))): scheduled session", level: .debug, category: "Notification")
            return false
        }

        // Only running -> idle
        guard transition.previousStatus == .running && transition.newStatus == .idle else { return false }

        // Already notified about this session reaching idle — skip
        if lastNotifiedStatus[transition.sessionId] == .idle {
            AppLogger.shared.log("[Notification] skip \(String(transition.sessionId.prefix(8))): already notified for idle", level: .debug, category: "Notification")
            return false
        }

        let isFav = favoriteSessionIds.contains(transition.sessionId)
        let isActive = transition.sessionId == activeSessionId && !isBackgrounded

        AppLogger.shared.log(
            "[Notification] firing for \(String(transition.sessionId.prefix(8))):"
            + " backgrounded=\(isBackgrounded) favorited=\(isFav) activeInForeground=\(isActive)",
            level: .info, category: "Notification"
        )
        return true
    }

    func fireNotification(title: String, body: String, sessionId: String) {
        // Record that we notified for this session reaching idle
        lastNotifiedStatus[sessionId] = .idle

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["sessionId": sessionId]

        let request = UNNotificationRequest(
            identifier: "session-\(sessionId)-idle",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
        AppLogger.shared.log("[Notification] scheduled local notification for \(String(sessionId.prefix(8)))", level: .debug, category: "Notification")
    }

    /// Check for missed transitions on app resume
    func checkMissedTransitions(currentSessions: [Session]) {
        AppLogger.shared.log("[Notification] checking missed transitions for \(currentSessions.count) sessions", level: .debug, category: "Notification")
        var missed = 0
        for session in currentSessions {
            if let prev = previousSessionStatuses[session.sessionId], prev == .running, session.status == .idle, !session.isScheduled {
                missed += 1
                fireNotification(
                    title: "Session finished",
                    body: "'\(session.displayTitle)' is ready for your next prompt",
                    sessionId: session.sessionId
                )
            }
            previousSessionStatuses[session.sessionId] = session.status
        }
        if missed > 0 {
            AppLogger.shared.log("[Notification] fired \(missed) missed transition notifications", level: .info, category: "Notification")
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let sessionId = userInfo["sessionId"] as? String else {
            AppLogger.shared.log("[Notification] tapped notification without sessionId — userInfo keys: \(userInfo.keys.map { "\($0)" }.joined(separator: ","))", level: .warning, category: "Notification")
            return
        }
        AppLogger.shared.log("[Notification] tapped notification for session \(String(sessionId.prefix(8)))", level: .info, category: "Notification")
        // Do NOT mutate app/UI state synchronously here: while this response handler
        // runs, UIKit takes a state-restoration snapshot, and a SwiftUI update inside
        // that transaction trips an NSAssertion in
        // -[UIApplication _performBlockAfterCATransactionCommitSynchronizes:] → SIGABRT.
        // Defer past the response transaction, then wait for the app to become active.
        Task { @MainActor [weak self] in
            for _ in 0..<20 where UIApplication.shared.applicationState != .active {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(100))
            guard let self else { return }
            if let navigate = self.onNavigateToSession {
                AppLogger.shared.log("[Notification] navigating via callback", level: .info, category: "Notification")
                self.pendingNavigationSessionId = nil
                navigate(sessionId)
            } else {
                AppLogger.shared.log("[Notification] no callback yet — storing pending navigation", level: .info, category: "Notification")
                self.pendingNavigationSessionId = sessionId
            }
        }
    }
}

struct SessionStatusTransition {
    let sessionId: String
    let previousStatus: SessionStatus
    let newStatus: SessionStatus
    let displayTitle: String
    let isScheduled: Bool
}
