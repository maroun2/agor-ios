import SwiftUI
import UserNotifications

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
            ConnectionSetupView(authService: appViewModel.authService)
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
    @State private var previousSessionStatuses: [String: SessionStatus] = [:]

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
                onLogout: {
                    socketService.disconnect()
                    appViewModel.authService.logout()
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
        }
        .onChange(of: chatVM.currentSessionId) { _, newValue in
            if newValue == nil {
                selectedSessionId = nil
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
        .task {
            socketService.connect()
            socketService.startHealthCheck(client: appViewModel.client)
            await navigationVM.loadBoards()
            // Seed session statuses so we can detect transitions for notifications
            for board in navigationVM.boardNodes {
                for wt in board.worktrees {
                    for session in wt.sessions {
                        previousSessionStatuses[session.sessionId] = session.status
                    }
                }
            }
            navigationVM.startPolling()
            await appViewModel.authService.fetchCurrentUser()
            chatVM.userId = appViewModel.currentUser?.userId ?? chatVM.userId
            setupCrossSessionNotifications()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ConnectionIndicator(socketService: socketService)
            }
        }
    }

    // MARK: - Background Recovery

    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            wasBackgrounded = true
            socketService.stopHealthCheck()
            chatVM.stopMessagePolling()
            navigationVM.stopPolling()

        case .active where wasBackgrounded:
            wasBackgrounded = false
            Task {
                // Phase 1: Reconnecting
                if socketService.connectionState != .connected {
                    withAnimation { reconnectPhase = .reconnecting }
                    socketService.reconnect()
                    try? await Task.sleep(for: .milliseconds(500))
                }

                // Phase 2: Updating data
                withAnimation { reconnectPhase = .updating }
                socketService.startHealthCheck(client: appViewModel.client)
                await navigationVM.refresh()
                navigationVM.startPolling()
                chatVM.refreshCurrentSession()

                // Phase 3: Done
                withAnimation { reconnectPhase = .done }
                try? await Task.sleep(for: .milliseconds(800))
                withAnimation { reconnectPhase = .idle }
            }

        default:
            break
        }
    }

    // MARK: - Cross-Session Notifications

    private func setupCrossSessionNotifications() {
        socketService.onSessionPatched { [self] session in
            let previousStatus = previousSessionStatuses[session.sessionId]
            previousSessionStatuses[session.sessionId] = session.status

            // Only toast for OTHER sessions
            guard session.sessionId != selectedSessionId else { return }

            let title = session.displayTitle

            switch session.status {
            case .awaitingPermission:
                toastManager.show(ToastMessage(
                    title: "'\(title)' needs permission",
                    subtitle: "Tap to review",
                    icon: "exclamationmark.shield",
                    sessionId: session.sessionId,
                    type: .permission
                ))

            case .awaitingInput:
                toastManager.show(ToastMessage(
                    title: "'\(title)' is asking a question",
                    subtitle: "Tap to answer",
                    icon: "questionmark.circle",
                    sessionId: session.sessionId,
                    type: .input
                ))

            case .completed:
                toastManager.show(ToastMessage(
                    title: "'\(title)' completed",
                    subtitle: nil,
                    icon: "checkmark.circle",
                    sessionId: session.sessionId,
                    type: .completed
                ))

            case .failed:
                toastManager.show(ToastMessage(
                    title: "'\(title)' failed",
                    subtitle: nil,
                    icon: "xmark.circle",
                    sessionId: session.sessionId,
                    type: .info
                ))

            default:
                break
            }

            // Fire local notification when session transitions running → idle
            if previousStatus == .running && session.status == .idle {
                let isFavorited = navigationVM.favoriteSessionIds.contains(session.sessionId)
                if isFavorited || wasBackgrounded {
                    fireLocalNotification(
                        title: "Session finished",
                        body: "'\(title)' is ready for your next prompt",
                        sessionId: session.sessionId
                    )
                }
            }
        }
    }

    private func fireLocalNotification(title: String, body: String, sessionId: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["sessionId": sessionId]

        let request = UNNotificationRequest(
            identifier: "session-\(sessionId)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
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
