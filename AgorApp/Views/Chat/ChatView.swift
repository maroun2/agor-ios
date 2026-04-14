import SwiftUI

struct ChatView: View {
    let viewModel: ChatViewModel
    let sessionId: String
    let socketService: SocketService
    let navigationVM: NavigationViewModel

    @State private var scrollProxy: ScrollViewProxy?
    @State private var showFileBrowser = false
    @State private var showMCPServers = false
    @State private var showSessionSettings = false
    @State private var showResetAlert = false
    @State private var fileBrowserVM: FileBrowserViewModel?
    @State private var mcpVM: MCPViewModel?

    var body: some View {
        chatContent
            .navigationTitle(viewModel.currentSession?.displayTitle ?? "Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { toolbarButtons } }
            .overlay { emptyStateOverlay }
            .sheet(isPresented: $showFileBrowser) { fileBrowserSheet }
            .sheet(isPresented: $showMCPServers) { mcpSheet }
            .onChange(of: showMCPServers) { _, showing in
                if showing, let session = viewModel.currentSession {
                    if mcpVM == nil || mcpVM?.sessionId != session.sessionId {
                        mcpVM = MCPViewModel(client: viewModel.client, socketService: socketService, sessionId: session.sessionId)
                    }
                }
            }
            .sheet(isPresented: $showSessionSettings) { sessionSettingsSheet }
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
            .onChange(of: viewModel.connectionState) { _, state in
                // Retry file list load when socket connects (initial load may have failed before socket was ready)
                if state == .connected, let vm = fileBrowserVM, vm.files.isEmpty {
                    Task { await vm.loadFiles() }
                }
            }
            .alert("Reset Session?", isPresented: $showResetAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Archive & Reset", role: .destructive) {
                    viewModel.resetSession { await navigationVM.refresh() }
                }
            } message: {
                Text("This will archive the current session and create a new one on the same worktree.")
            }
    }

    // MARK: - Body helpers

    private var chatContent: some View {
        VStack(spacing: 0) {
            statusBanners
            messageScrollView
            PromptInputBar(viewModel: viewModel)
        }
    }

    @ViewBuilder private var emptyStateOverlay: some View {
        if viewModel.isLoadingMessages && viewModel.messages.isEmpty {
            ProgressView("Loading messages...")
        } else if viewModel.messages.isEmpty && viewModel.activeStreams.isEmpty && !viewModel.isLoadingMessages && viewModel.error == nil {
            ContentUnavailableView("No Messages", systemImage: "bubble.left", description: Text("Send a prompt to get started"))
        }
    }

    @ViewBuilder private var fileBrowserSheet: some View {
        if let vm = fileBrowserVM { FileBrowserView(viewModel: vm) }
    }

    @ViewBuilder private var mcpSheet: some View {
        if let vm = mcpVM {
            MCPServerListView(viewModel: vm)
        }
    }

    @ViewBuilder private var sessionSettingsSheet: some View {
        if let session = viewModel.currentSession {
            SessionSettingsSheet(session: session, socketService: socketService)
        }
    }

    // MARK: - Toolbar

    @ViewBuilder private var toolbarButtons: some View {
        if let session = viewModel.currentSession {
            HStack(spacing: 8) {
                if !session.worktreeId.isEmpty {
                    Button { showFileBrowser = true } label: {
                        Image(systemName: "folder").foregroundStyle(.secondary).font(.system(size: 16))
                    }
                }
                Button { showSessionSettings = true } label: {
                    Image(systemName: "gearshape").foregroundStyle(.secondary).font(.system(size: 16))
                }
                Button { showMCPServers = true } label: {
                    Image(systemName: "server.rack").foregroundStyle(.secondary).font(.system(size: 16))
                }
                Button { viewModel.archiveCurrentSession() } label: {
                    Image(systemName: "archivebox").foregroundStyle(.secondary).font(.system(size: 16))
                }
                Button { showResetAlert = true } label: {
                    Image(systemName: "arrow.counterclockwise").foregroundStyle(.secondary).font(.system(size: 16))
                }
                if session.isPlanMode { PlanModeBadge() }
                if viewModel.canStopSession {
                    Button {
                        HapticFeedback.light()
                        viewModel.stopSession()
                    } label: {
                        if viewModel.isStoppingSession {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "stop.circle.fill").foregroundStyle(.red).font(.system(size: 18))
                        }
                    }
                } else {
                    StatusBadge(status: session.status)
                }
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder private var statusBanners: some View {
        if viewModel.error != nil {
            ConnectionLostBanner(
                error: viewModel.error!,
                onRetry: {
                    viewModel.error = nil
                    Task { await viewModel.loadMessages(sessionId) }
                }
            )
        }
        if viewModel.connectionState == .disconnected {
            HStack {
                Image(systemName: "wifi.slash").foregroundStyle(.red)
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
        if viewModel.sessionNeedsAttention {
            AttentionBar(viewModel: viewModel, scrollProxy: scrollProxy)
        }
        if viewModel.currentSession?.isPlanMode == true {
            PlanModeBar()
        }
    }

    private var messageScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if viewModel.hasMore {
                        Button("Load earlier messages") {
                            Task { await viewModel.loadMore() }
                        }
                        .font(.caption)
                        .padding()
                    }
                    ForEach(viewModel.displayItems) { item in
                        messageRow(item)
                    }
                    if viewModel.currentSession?.status == .running && viewModel.activeStreams.isEmpty {
                        AgentWorkingIndicator()
                    }
                }
                .padding(.vertical, 8)
                // Bottom spacer to ensure last message scrolls above input bar
                Color.clear
                    .frame(height: 60)
                    .id("bottom")
                    .onAppear {
                        viewModel.userIsNearBottom = true
                        AppLogger.shared.log("[Scroll] bottom marker appeared — userIsNearBottom=true", level: .debug, category: "Scroll")
                    }
                    .onDisappear {
                        viewModel.userIsNearBottom = false
                        AppLogger.shared.log("[Scroll] bottom marker disappeared — userIsNearBottom=false", level: .debug, category: "Scroll")
                    }
            }
            .onAppear { scrollProxy = proxy }
            .onChange(of: viewModel.scrollToBottomToken) { _, token in
                let delay: Double = viewModel.isReconnectScroll ? 0.3 : 0.05
                if viewModel.isReconnectScroll { viewModel.isReconnectScroll = false }
                AppLogger.shared.log("[Scroll] scrollToBottom executing (token=\(token), delay=\(delay))", level: .debug, category: "Scroll")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.scrollToMessageId) { _, targetId in
                guard let targetId else { return }
                viewModel.scrollToMessageId = nil
                AppLogger.shared.log("[Scroll] scrollToMessage executing → \(targetId)", level: .debug, category: "Scroll")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(targetId, anchor: .center)
                    }
                    // Clear flag after animation completes
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        viewModel.scrollToMessageInProgress = false
                        AppLogger.shared.log("[Scroll] scrollToMessageInProgress cleared", level: .debug, category: "Scroll")
                    }
                }
            }
        }
    }

    @ViewBuilder private func messageRow(_ item: DisplayItem) -> some View {
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
                knownSessionNames: knownSessionNames,
                onOpenFile: { path in openFileInBrowser(path) },
                onOpenSession: { hash in navigateToSession(hash) }
            )
            .id(item.id)
        case .streaming(let streaming):
            StreamingMessageView(streaming: streaming)
                .id(item.id)
        }
    }

    // MARK: - Enhanced Text Helpers

    private var knownSessionIds: Set<String> {
        Set(navigationVM.boardNodes.flatMap { $0.worktrees.flatMap { $0.sessions.map(\.sessionId) } })
    }

    private var knownSessionNames: [String: String] {
        var map: [String: String] = [:]
        for board in navigationVM.boardNodes {
            for wt in board.worktrees {
                for session in wt.sessions {
                    map[session.sessionId] = session.displayTitle
                }
            }
        }
        return map
    }

    private func openFileInBrowser(_ path: String) {
        if let vm = fileBrowserVM {
            let components = path.components(separatedBy: "/")
            if components.count > 1 {
                vm.currentPath = components.dropLast().joined(separator: "/")
            } else {
                vm.currentPath = ""
            }
            vm.pendingFilePath = path
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
            let targetId = viewModel.currentPendingPermissionId ?? viewModel.currentPendingInputId
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
