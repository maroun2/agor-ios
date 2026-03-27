import SwiftUI

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
                selectedSessionId: $selectedSessionId
            )
        } detail: {
            if let sessionId = selectedSessionId {
                ChatView(viewModel: chatVM, sessionId: sessionId)
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
            await appViewModel.authService.fetchCurrentUser()
            chatVM.userId = appViewModel.currentUser?.userId ?? chatVM.userId
            setupCrossSessionNotifications()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 8) {
                    // Logout button
                    Button {
                        socketService.disconnect()
                        appViewModel.authService.logout()
                    } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.caption)
                    }

                    ConnectionIndicator(socketService: socketService)
                }
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

        case .active where wasBackgrounded:
            wasBackgrounded = false
            // Reconnect socket
            if socketService.connectionState != .connected {
                socketService.reconnect()
            }
            socketService.startHealthCheck(client: appViewModel.client)
            // Re-fetch state
            Task {
                await navigationVM.refresh()
                chatVM.refreshCurrentSession()
            }

        default:
            break
        }
    }

    // MARK: - Cross-Session Notifications

    private func setupCrossSessionNotifications() {
        // Subscribe to session patches for toast notifications on OTHER sessions
        socketService.onSessionPatched { [self] session in
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
        }
    }
}
