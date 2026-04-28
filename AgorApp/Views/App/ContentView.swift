import SwiftUI

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
                ChatView(viewModel: chatVM, sessionId: sessionId, socketService: socketService, navigationVM: navigationVM)
            } else {
                ContentUnavailableView(
                    "Select a Session",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Choose a session from the sidebar to start chatting")
                )
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if chatVM.voiceModeEnabled, selectedSessionId != chatVM.voiceSessionId {
                VoiceFloatingButton(voiceState: chatVM.voiceService?.state ?? .disabled) {
                    selectedSessionId = chatVM.voiceSessionId
                }
                .padding(.trailing, 16)
                .padding(.bottom, 24)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .toastOverlay(manager: toastManager) { sessionId in
            selectedSessionId = sessionId
        }
        .overlay(alignment: .top) {
            if reconnectPhase != .idle {
                ReconnectBanner(phase: reconnectPhase)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: selectedSessionId) { _, newValue in
            if let sessionId = newValue {
                chatVM.selectSession(sessionId)
            }
            notificationManager.activeSessionId = newValue
        }
        .onChange(of: chatVM.currentSessionId) { _, newValue in
            if newValue == nil {
                selectedSessionId = nil
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
        .onChange(of: notificationManager.pendingNavigationSessionId) { _, sessionId in
            if let sessionId {
                selectedSessionId = sessionId
                notificationManager.pendingNavigationSessionId = nil
            }
        }
        .onChange(of: navigationVM.favoriteSessionIds) { _, newValue in
            notificationManager.favoriteSessionIds = newValue
        }
        .task {
            // Force logout when token refresh fails permanently (stops 401 flood + rate-limit cascade)
            appViewModel.client.onSessionExpired = {
                AppLogger.shared.log("[App] Session expired — forcing logout", level: .info, category: "App")
                socketService.disconnect()
                navigationVM.stopPolling()
                navigationVM.clearCache()
                appViewModel.authService.logout()
            }

            AppLogger.shared.log("[App] startup: connecting socket", level: .debug, category: "App")
            socketService.connect()
            socketService.startHealthCheck(client: appViewModel.client)

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

    // MARK: - Background Recovery

    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        let oldLabel = "\(oldPhase)".lowercased()

        switch newPhase {
        case .background:
            wasBackgrounded = true
            notificationManager.isBackgrounded = true
            socketService.stopHealthCheck()
            chatVM.stopMessagePolling()
            navigationVM.stopPolling()
            // Voice stays running in background — user disabled it explicitly to stop it
            AppLogger.shared.log("[App] lifecycle: \(oldLabel) → background (stopped polling)", level: .info, category: "App")

        case .active where wasBackgrounded:
            wasBackgrounded = false
            notificationManager.isBackgrounded = false
            AppLogger.shared.log("[App] lifecycle: \(oldLabel) → active (reconnecting)", level: .info, category: "App")
            Task {
                // Phase 1: Reconnecting
                if socketService.connectionState != .connected {
                    AppLogger.shared.log("[App] reconnect: phase 1 — reconnecting socket", level: .debug, category: "App")
                    withAnimation { reconnectPhase = .reconnecting }
                    socketService.reconnect()
                    try? await Task.sleep(for: .milliseconds(500))
                }

                // Phase 2: Updating data
                AppLogger.shared.log("[App] reconnect: phase 2 — refreshing data", level: .debug, category: "App")
                withAnimation { reconnectPhase = .updating }
                socketService.startHealthCheck(client: appViewModel.client)
                await navigationVM.refresh()
                navigationVM.startPolling()
                chatVM.refreshCurrentSession()

                // Check for missed transitions while backgrounded
                let allSessions = navigationVM.boardNodes.flatMap { $0.worktrees.flatMap { $0.sessions } }
                notificationManager.checkMissedTransitions(currentSessions: allSessions)

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
