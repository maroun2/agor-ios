import SwiftUI

struct ChatView: View {
    let viewModel: ChatViewModel
    let sessionId: String
    let socketService: SocketService
    let navigationVM: NavigationViewModel

    @State private var scrollProxy: ScrollViewProxy?
    @State private var showFileBrowser = false
    @State private var showMCPServers = false
    @State private var showResetAlert = false
    @State private var fileBrowserVM: FileBrowserViewModel?

    var body: some View {
        VStack(spacing: 0) {
            // Connection lost banner
            if viewModel.error != nil {
                ConnectionLostBanner(
                    error: viewModel.error!,
                    onRetry: {
                        viewModel.error = nil
                        Task { await viewModel.loadMessages(sessionId) }
                    }
                )
            }

            // Disconnected indicator
            if viewModel.connectionState == .disconnected {
                HStack {
                    Image(systemName: "wifi.slash")
                        .foregroundStyle(.red)
                    Text("Disconnected from server")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.red.opacity(0.08))
            }

            // Attention bar
            if viewModel.sessionNeedsAttention {
                AttentionBar(viewModel: viewModel, scrollProxy: scrollProxy)
            }

            // Plan mode indicator
            if viewModel.currentSession?.isPlanMode == true {
                PlanModeBar()
            }

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Load more
                        if viewModel.hasMore {
                            Button("Load earlier messages") {
                                Task { await viewModel.loadMore() }
                            }
                            .font(.caption)
                            .padding()
                        }

                        ForEach(viewModel.displayItems) { item in
                            switch item {
                            case .taskHeader(let task):
                                TaskHeader(
                                    task: task,
                                    isCollapsed: viewModel.collapsedTaskIds.contains(task.taskId),
                                    onToggle: { viewModel.toggleTaskCollapsed(task.taskId) }
                                )
                                .id(item.id)

                            case .message(let message):
                                MessageBubble(
                                    message: message,
                                    viewModel: viewModel,
                                    worktreeId: viewModel.currentSession?.worktreeId,
                                    socketService: socketService,
                                    knownSessionIds: knownSessionIds,
                                    knownFilePaths: fileBrowserVM?.filePaths ?? [],
                                    onOpenFile: { path in openFileInBrowser(path) },
                                    onOpenSession: { hash in navigateToSession(hash) }
                                )
                                .id(item.id)

                            case .streaming(let streaming):
                                StreamingMessageView(streaming: streaming)
                                    .id(item.id)
                            }
                        }

                        // Working indicator — shown when running but no stream yet
                        if viewModel.currentSession?.status == .running && viewModel.activeStreams.isEmpty {
                            AgentWorkingIndicator()
                        }
                    }
                    .padding(.vertical, 8)

                    // Bottom anchor outside LazyVStack so it's always rendered
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .onAppear { viewModel.userIsNearBottom = true }
                        .onDisappear { viewModel.userIsNearBottom = false }
                }
                .onAppear { scrollProxy = proxy }
                .onChange(of: viewModel.scrollToBottomToken) { _, _ in
                    // Use longer delay after reconnect to let LazyVStack finish layout
                    let delay: Double = viewModel.isReconnectScroll ? 0.3 : 0.05
                    if viewModel.isReconnectScroll { viewModel.isReconnectScroll = false }
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }

            // Prompt input
            PromptInputBar(viewModel: viewModel)
        }
        .navigationTitle(viewModel.currentSession?.displayTitle ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let session = viewModel.currentSession {
                    HStack(spacing: 8) {
                        // File browser
                        if !session.worktreeId.isEmpty {
                            Button {
                                showFileBrowser = true
                            } label: {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 16))
                            }
                        }

                        // MCP servers
                        Button {
                            showMCPServers = true
                        } label: {
                            Image(systemName: "server.rack")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 16))
                        }

                        // Archive button
                        Button {
                            viewModel.archiveCurrentSession()
                        } label: {
                            Image(systemName: "archivebox")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 16))
                        }

                        // Reset/clean button
                        Button {
                            showResetAlert = true
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 16))
                        }

                        if session.isPlanMode {
                            PlanModeBadge()
                        }

                        // Status icon — doubles as stop button when running
                        if viewModel.canStopSession {
                            Button {
                                HapticFeedback.light()
                                viewModel.stopSession()
                            } label: {
                                if viewModel.isStoppingSession {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: "stop.circle.fill")
                                        .foregroundStyle(.red)
                                        .font(.system(size: 18))
                                }
                            }
                        } else {
                            StatusBadge(status: session.status)
                        }

                    }
                }
            }
        }
        .overlay {
            if viewModel.isLoadingMessages && viewModel.messages.isEmpty {
                ProgressView("Loading messages...")
            } else if viewModel.messages.isEmpty && viewModel.activeStreams.isEmpty && !viewModel.isLoadingMessages && viewModel.error == nil {
                ContentUnavailableView(
                    "No Messages",
                    systemImage: "bubble.left",
                    description: Text("Send a prompt to get started")
                )
            }
        }
        .sheet(isPresented: $showFileBrowser) {
            if let vm = fileBrowserVM {
                FileBrowserView(viewModel: vm)
            }
        }
        .sheet(isPresented: $showMCPServers) {
            if let session = viewModel.currentSession {
                MCPServerListView(viewModel: MCPViewModel(
                    client: viewModel.client,
                    socketService: socketService,
                    sessionId: session.sessionId
                ))
            }
        }
        .onChange(of: viewModel.currentSession?.worktreeId) { _, newWorktreeId in
            if let wid = newWorktreeId, fileBrowserVM?.worktreeId != wid {
                let vm = FileBrowserViewModel(worktreeId: wid, socketService: socketService)
                fileBrowserVM = vm
                Task { await vm.loadFiles() }
            }
        }
        .onAppear {
            if fileBrowserVM == nil, let wid = viewModel.currentSession?.worktreeId {
                let vm = FileBrowserViewModel(worktreeId: wid, socketService: socketService)
                fileBrowserVM = vm
                Task { await vm.loadFiles() }
            }
        }
        .alert("Reset Session?", isPresented: $showResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Archive & Reset", role: .destructive) {
                viewModel.resetSession {
                    await navigationVM.refresh()
                }
            }
        } message: {
            Text("This will archive the current session and create a new one on the same worktree.")
        }
    }

    // MARK: - Enhanced Text Helpers

    private var knownSessionIds: Set<String> {
        Set(navigationVM.boardNodes.flatMap { $0.worktrees.flatMap { $0.sessions.map(\.sessionId) } })
    }

    private func openFileInBrowser(_ path: String) {
        if let vm = fileBrowserVM {
            let components = path.components(separatedBy: "/")
            if components.count > 1 {
                vm.currentPath = components.dropLast().joined(separator: "/")
            } else {
                vm.currentPath = ""
            }
        }
        showFileBrowser = true
    }

    private func navigateToSession(_ hash: String) {
        let allSessions = navigationVM.boardNodes.flatMap { $0.worktrees.flatMap(\.sessions) }
        if let session = allSessions.first(where: { $0.sessionId.hasPrefix(hash) || $0.sessionId == hash }) {
            viewModel.selectSession(session.sessionId)
        }
    }
}

// MARK: - Attention Bar

private struct AttentionBar: View {
    let viewModel: ChatViewModel
    let scrollProxy: ScrollViewProxy?

    var body: some View {
        Button {
            let targetId = viewModel.firstPendingPermissionId ?? viewModel.firstPendingInputId
            if let targetId {
                withAnimation {
                    scrollProxy?.scrollTo("msg-\(targetId)", anchor: .center)
                }
            }
        } label: {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Needs attention")
                    .font(.caption.weight(.medium))
                Image(systemName: "arrow.down")
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Plan Mode Bar

private struct PlanModeBar: View {
    var body: some View {
        HStack {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.purple)
            Text("Plan Mode — read-only, no tool execution")
                .font(.caption)
                .foregroundStyle(.purple)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(.purple.opacity(0.08))
    }
}

// MARK: - Plan Mode Badge

struct PlanModeBadge: View {
    var body: some View {
        Text("Plan")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.purple.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.purple)
    }
}

// MARK: - Connection Lost Banner

private struct ConnectionLostBanner: View {
    let error: String
    let onRetry: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.red)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Retry", action: onRetry)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.red.opacity(0.08))
    }
}
