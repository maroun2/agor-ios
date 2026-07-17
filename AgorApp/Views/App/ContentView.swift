import SwiftUI
import UIKit

enum ReconnectPhase {
    case idle
    case reconnecting
    case updating
    case done
}

struct ContentView: View {
    let appViewModel: AppViewModel

    var body: some View {
        if appViewModel.isAuthenticated {
            MainNavigationView(appViewModel: appViewModel)
        } else {
            ConnectionSetupView(appViewModel: appViewModel)
        }
    }
}

// MARK: - Main Navigation (NavigationSplitView)

struct MainNavigationView: View {
    let appViewModel: AppViewModel

    @Environment(\.scenePhase) private var scenePhase

    @State private var navigationVM: NavigationViewModel
    @State private var chatVM: ChatViewModel
    @State private var socketService: SocketService
    @State private var streamingService: StreamingService
    @State private var toastManager = ToastManager()
    @State private var selectedSessionId: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var wasBackgrounded = false
    @State private var reconnectPhase: ReconnectPhase = .idle
    @State private var notificationManager = NotificationManager.shared
    @State private var tokenRefreshTask: Task<Void, Never>?

    init(appViewModel: AppViewModel) {
        self.appViewModel = appViewModel
        let socket = SocketService(client: appViewModel.client)
        let streaming = StreamingService()
        _socketService = State(initialValue: socket)
        _streamingService = State(initialValue: streaming)
        _navigationVM = State(initialValue: NavigationViewModel(
            client: appViewModel.client,
            socketService: socket
        ))
        _chatVM = State(initialValue: ChatViewModel(
            client: appViewModel.client,
            socketService: socket,
            streamingService: streaming,
            userId: appViewModel.currentUser?.userId ?? ""
        ))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(
                    viewModel: navigationVM,
                    selectedSessionId: $selectedSessionId,
                    appViewModel: appViewModel,
                    socketService: socketService,
                    chatVM: chatVM,
                    onLogout: {
                        socketService.disconnect()
                        navigationVM.clearCache()
                        appViewModel.authService.logout()
                    },
                    onServerSwitch: { profile in
                        Task {
                            navigationVM.clearCache()
                            await appViewModel.switchServer(to: profile, socketService: socketService)
                            await navigationVM.refresh()
                        }
                    },
                    onClearCache: {
                        navigationVM.clearCache()
                        Task { await navigationVM.refresh() }
                    }
                )
            } detail: {
                if let sessionId = selectedSessionId {
                    ChatView(
                        viewModel: chatVM,
                        sessionId: sessionId,
                        socketService: socketService,
                        navigationVM: navigationVM,
                        onOpenSession: { selectedSessionId = $0 }
                    )
                } else {
                    ContentUnavailableView(
                        "Select a Session",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Choose a session from the sidebar to start chatting")
                    )
                }
            }

        .voiceFloatingOverlay(chatVM: chatVM, onNavigate: { selectedSessionId = $0 })
        .toastOverlay(manager: toastManager) { sessionId in
            selectedSessionId = sessionId
        }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                if !appViewModel.networkMonitor.isOnline {
                    OfflineBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if reconnectPhase != .idle {
                    ReconnectBanner(phase: reconnectPhase)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: appViewModel.networkMonitor.isOnline)
        }
        .onChange(of: selectedSessionId) { _, newValue in
            if let sessionId = newValue, sessionId != chatVM.currentSessionId {
                chatVM.selectSession(sessionId)
            }
            notificationManager.activeSessionId = newValue
        }
        .onChange(of: chatVM.currentSessionId) { _, newValue in
            if selectedSessionId != newValue {
                selectedSessionId = newValue
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
        .onChange(of: notificationManager.pendingNavigationSessionId, initial: true) { _, sessionId in
            if let sessionId {
                AppLogger.shared.log("[Notification] onChange consumed pending navigation → \(String(sessionId.prefix(8)))", level: .info, category: "Notification")
                selectedSessionId = sessionId
                notificationManager.pendingNavigationSessionId = nil
            }
        }
        .onAppear {
            // Deterministic notification-tap navigation: delegate calls this directly,
            // no dependency on SwiftUI observation of pendingNavigationSessionId.
            notificationManager.onNavigateToSession = { sessionId in
                AppLogger.shared.log("[Notification] callback navigation → \(String(sessionId.prefix(8)))", level: .info, category: "Notification")
                selectedSessionId = sessionId
            }
            // Cold launch: tap may have arrived before this view mounted
            if let pending = notificationManager.pendingNavigationSessionId {
                AppLogger.shared.log("[Notification] onAppear consumed pending navigation → \(String(pending.prefix(8)))", level: .info, category: "Notification")
                notificationManager.pendingNavigationSessionId = nil
                selectedSessionId = pending
            }
        }
        .onDisappear {
            notificationManager.onNavigateToSession = nil
        }
        .onChange(of: navigationVM.favoriteSessionIds) { _, newValue in
            notificationManager.favoriteSessionIds = newValue
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
        .onChange(of: appViewModel.networkMonitor.isOnline) { _, isOnline in
            if isOnline {
                AppLogger.shared.log("[App] Network restored — reconnecting", level: .info, category: "App")
                socketService.connect()
                navigationVM.startPolling()
                Task { await navigationVM.refresh() }
            } else {
                AppLogger.shared.log("[App] Network lost — pausing requests", level: .warning, category: "App")
                socketService.disconnect()
                navigationVM.stopPolling()
            }
        }
        .task {
            // Wire silent re-auth: AgorClient calls this on 401 before giving up
            appViewModel.client.onSilentReAuth = {
                guard await appViewModel.authService.silentReauth() else {
                    throw AgorAPIError.tokenRefreshFailed
                }
                Task { @MainActor in socketService.reconnect() }
            }
            // Called only after silentReAuth also failed — force logout
            appViewModel.client.onSessionExpired = {
                AppLogger.shared.log("[App] All auth recovery failed — logging out", level: .error, category: "App")
                socketService.disconnect()
                navigationVM.stopPolling()
                navigationVM.clearCache()
                appViewModel.authService.logout()
            }

            // Socket-level auth failure (FeathersJS 401) — try silent re-auth before giving up
            socketService.onAuthFailure = {
                Task {
                    AppLogger.shared.log("[App] Socket auth failed — attempting silent re-auth", level: .info, category: "App")
                    if await appViewModel.authService.silentReauth() {
                        AppLogger.shared.log("[App] Silent re-auth succeeded — reconnecting socket", level: .info, category: "App")
                        socketService.reconnect()
                        await appViewModel.authService.fetchCurrentUser()
                    } else {
                        AppLogger.shared.log("[App] Socket auth recovery failed — logging out", level: .error, category: "App")
                        socketService.disconnect()
                        navigationVM.stopPolling()
                        navigationVM.clearCache()
                        appViewModel.authService.logout()
                    }
                }
            }

            AppLogger.shared.log("[App] startup: connecting socket", level: .debug, category: "App")
            socketService.connect()
            socketService.startHealthCheck(client: appViewModel.client)
            startTokenRefreshTimer()

            AppLogger.shared.log("[App] startup: loading boards", level: .debug, category: "App")
            await navigationVM.loadBoards()

            // Seed session statuses into NotificationManager (reference type — always current)
            let allSessions = navigationVM.boardNodes.flatMap { $0.worktrees.flatMap { $0.sessions } }
            notificationManager.seedStatuses(from: allSessions)

            AppLogger.shared.log("[App] startup: polling started", level: .debug, category: "App")
            navigationVM.startPolling()
            await appViewModel.authService.fetchCurrentUser()
            chatVM.userId = appViewModel.currentUser?.userId ?? chatVM.userId

            // Setup notification handling via NotificationManager (reference semantics — always current)
            socketService.onSessionPatched { session in
                // Update notification state
                if let transition = notificationManager.handleSessionUpdate(session) {
                    if notificationManager.shouldNotify(for: transition) {
                        notificationManager.fireNotification(
                            title: "Session finished",
                            body: "'\(transition.displayTitle)' is ready for your next prompt",
                            sessionId: transition.sessionId
                        )
                    }
                }

                // Still show toasts for other sessions
                guard session.sessionId != selectedSessionId else { return }
                let title = session.displayTitle
                switch session.status {
                case .awaitingPermission:
                    toastManager.show(ToastMessage(title: "'\(title)' needs permission", subtitle: "Tap to review", icon: "exclamationmark.shield", sessionId: session.sessionId, type: .permission))
                case .awaitingInput:
                    toastManager.show(ToastMessage(title: "'\(title)' is asking a question", subtitle: "Tap to answer", icon: "questionmark.circle", sessionId: session.sessionId, type: .input))
                case .completed:
                    toastManager.show(ToastMessage(title: "'\(title)' completed", subtitle: nil, icon: "checkmark.circle", sessionId: session.sessionId, type: .completed))
                case .failed:
                    toastManager.show(ToastMessage(title: "'\(title)' failed", subtitle: nil, icon: "xmark.circle", sessionId: session.sessionId, type: .info))
                default: break
                }
            }

            AppLogger.shared.log("[App] startup: complete", level: .info, category: "App")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionIndicator(socketService: socketService)
            }
        }
    }

    // MARK: - Deep Link Handling

    /// Handles agor://session/{sessionId}/chat and agor://session/{sessionId}/voice
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "agor",
              url.host == "session" else { return }
        let components = url.pathComponents.filter { $0 != "/" }
        guard let sessionId = components.first else { return }
        let action = components.count >= 2 ? components[1] : "chat"

        selectedSessionId = sessionId

        if action == "voice" {
            // Give ChatView a moment to load the session before enabling voice mode
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                chatVM.voiceModeEnabled = true
            }
        }
    }

    // MARK: - Background Recovery

    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        let oldLabel = "\(oldPhase)".lowercased()

        switch newPhase {
        case .background:
            wasBackgrounded = true
            notificationManager.isBackgrounded = true
            socketService.stopHealthCheck()
            stopTokenRefreshTimer()
            chatVM.stopPolling()
            navigationVM.stopPolling()

            // If voice mode is active, play silent audio to keep the process alive.
            // The audio background mode prevents iOS from suspending us, so the
            // socket stays connected and voice mode continues working.
            if chatVM.voiceModeEnabled {
                chatVM.voiceService?.startBackgroundKeepAlive()
                AppLogger.shared.log("[App] lifecycle: voice active — silent audio keep-alive started", level: .info, category: "App")
            }

            // Request ~30s extended execution for one HTTP poll before suspension.
            // This fires even without voice mode — catches status changes missed
            // while the socket was dying.
            let bgTaskId = UIApplication.shared.beginBackgroundTask {
                // Expiration handler — nothing to clean up
            }
            if bgTaskId != .invalid {
                Task {
                    await BackgroundSessionPoller.shared.pollOnce()
                    UIApplication.shared.endBackgroundTask(bgTaskId)
                }
            }

            AppLogger.shared.log("[App] lifecycle: \(oldLabel) → background (stopped polling, began background task)", level: .info, category: "App")

        case .active where wasBackgrounded:
            wasBackgrounded = false
            notificationManager.isBackgrounded = false

            // Stop silent audio keep-alive (no longer needed in foreground)
            chatVM.voiceService?.stopBackgroundKeepAlive()

            AppLogger.shared.log("[App] lifecycle: \(oldLabel) → active (reconnecting)", level: .info, category: "App")
            Task {
                // Phase 0: Proactive token refresh before reconnecting
                // Token may have expired while backgrounded — refresh it first so the
                // socket reconnect uses a fresh token in extraHeaders.
                await appViewModel.client.refreshTokenIfNeeded(bufferSeconds: 120)

                // Phase 1: Reconnecting
                if socketService.connectionState != .connected {
                    AppLogger.shared.log("[App] reconnect: phase 1 — reconnecting socket", level: .debug, category: "App")
                    withAnimation { reconnectPhase = .reconnecting }
                    socketService.reconnect()
                    try? await Task.sleep(for: .milliseconds(500))
                } else {
                    // Transport survived but its auth token may be stale after the proactive
                    // refresh above — re-emit FeathersJS auth so socket service calls don't 401.
                    socketService.reauthenticate()
                }

                // Phase 2: Updating data
                AppLogger.shared.log("[App] reconnect: phase 2 — refreshing data", level: .debug, category: "App")
                withAnimation { reconnectPhase = .updating }
                socketService.startHealthCheck(client: appViewModel.client)
                startTokenRefreshTimer()
                await navigationVM.refresh()
                navigationVM.startPolling()
                chatVM.refreshCurrentSession()

                // Check for missed transitions while backgrounded
                let allSessions = navigationVM.boardNodes.flatMap { $0.worktrees.flatMap { $0.sessions } }
                notificationManager.checkMissedTransitions(currentSessions: allSessions)

                // Refresh widget data on foreground
                await navigationVM.refreshWidgetData()

                // Phase 3: Done
                withAnimation { reconnectPhase = .done }
                try? await Task.sleep(for: .milliseconds(800))
                withAnimation { reconnectPhase = .idle }
                AppLogger.shared.log("[App] reconnect: complete", level: .debug, category: "App")
            }

        default:
            break
        }
    }

    // MARK: - Proactive Token Refresh

    /// Refresh proactively on foreground / periodically; re-authenticate the socket so it never runs on a stale token.
    private func startTokenRefreshTimer() {
        tokenRefreshTask?.cancel()
        tokenRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(12 * 60))
                guard !Task.isCancelled else { break }
                let refreshed = await appViewModel.client.refreshTokenIfNeeded(bufferSeconds: 180)
                if refreshed {
                    AppLogger.shared.log("[App] proactive token refresh: OK", level: .debug, category: "App")
                    if socketService.connectionState == .connected {
                        socketService.reauthenticate()
                    }
                } else {
                    AppLogger.shared.log("[App] proactive token refresh: failed — will retry next cycle", level: .warning, category: "App")
                }
            }
        }
    }

    private func stopTokenRefreshTimer() {
        tokenRefreshTask?.cancel()
        tokenRefreshTask = nil
    }
}

// MARK: - Reconnect Banner

private struct ReconnectBanner: View {
    let phase: ReconnectPhase

    var body: some View {
        HStack(spacing: 8) {
            if phase == .done {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            Text(phaseLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    private var phaseLabel: String {
        switch phase {
        case .idle: ""
        case .reconnecting: "Reconnecting..."
        case .updating: "Updating..."
        case .done: "Updated"
        }
    }
}

// MARK: - Offline Banner

private struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
                .imageScale(.small)
            Text("No network connection")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }
}
