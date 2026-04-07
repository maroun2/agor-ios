import SwiftUI

/// Identifiable wrapper for presenting a file browser sheet for a specific worktree.
private struct FileBrowserTarget: Identifiable {
    let id: String // worktreeId
}

struct SidebarView: View {
    let viewModel: NavigationViewModel
    @Binding var selectedSessionId: String?
    let appViewModel: AppViewModel
    let socketService: SocketService
    let onLogout: () -> Void

    let onServerSwitch: ((ServerProfile) -> Void)?

    @State private var showSettings = false
    @State private var fileBrowserTarget: FileBrowserTarget?

    var body: some View {
        List(selection: $selectedSessionId) {
            // Needs Attention Section
            if !viewModel.attentionSessions.isEmpty {
                Section {
                    ForEach(viewModel.attentionSessions) { session in
                        let ctx = viewModel.findContext(for: session.sessionId)
                        NavigationLink(value: session.sessionId) {
                            AttentionSessionRow(session: session, boardIcon: ctx?.boardIcon)
                        }
                        .contextMenu {
                            FavoriteButton(sessionId: session.sessionId, viewModel: viewModel)
                            BrowseFilesButton(worktreeId: session.worktreeId, target: $fileBrowserTarget)
                            Divider()
                            CleanAndResetButton(session: session, viewModel: viewModel, selectedSessionId: $selectedSessionId)
                            ArchiveButton(sessionId: session.sessionId, viewModel: viewModel)
                        }
                    }
                } header: {
                    Label("Needs Attention", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            // Important Section — running, ready for prompt, favorites, 3 most recent
            if !viewModel.importantSessions.isEmpty {
                Section {
                    ForEach(viewModel.importantSessions) { session in
                        let ctx = viewModel.findContext(for: session.sessionId)
                        NavigationLink(value: session.sessionId) {
                            ImportantSessionRow(
                                session: session,
                                isFavorite: viewModel.favoriteSessionIds.contains(session.sessionId),
                                boardName: ctx?.boardName,
                                worktreeName: ctx?.worktreeName,
                                boardIcon: ctx?.boardIcon
                            )
                        }
                        .contextMenu {
                            FavoriteButton(sessionId: session.sessionId, viewModel: viewModel)
                            BrowseFilesButton(worktreeId: session.worktreeId, target: $fileBrowserTarget)
                            Divider()
                            CleanAndResetButton(session: session, viewModel: viewModel, selectedSessionId: $selectedSessionId)
                            ArchiveButton(sessionId: session.sessionId, viewModel: viewModel)
                        }
                    }
                } header: {
                    Label("Important", systemImage: "sparkles")
                        .foregroundStyle(.primary)
                }
            }

            // Boards
            ForEach(viewModel.boardNodes) { boardNode in
                Section {
                    DisclosureGroup(isExpanded: Binding(
                        get: { boardNode.isExpanded },
                        set: {
                            boardNode.isExpanded = $0
                            viewModel.setBoardExpanded(boardNode.board.boardId, expanded: $0)
                            if $0 {
                                Task { await viewModel.loadWorktrees(for: boardNode) }
                            }
                        }
                    )) {
                        if boardNode.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            ForEach(boardNode.worktrees) { wtNode in
                                WorktreeSection(
                                    worktreeNode: wtNode,
                                    viewModel: viewModel,
                                    socketService: socketService,
                                    selectedSessionId: $selectedSessionId
                                )
                            }
                        }
                    } label: {
                        BoardRow(board: boardNode.board, attentionCount: boardNode.attentionCount)
                    }
                    .selectionDisabled()
                }
            }

            // Settings footer
            Section {
                Button {
                    showSettings = true
                } label: {
                    HStack {
                        Image(systemName: "gearshape")
                            .foregroundStyle(.secondary)
                        Text("Settings")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(GitVersion.hash)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(ServerProfileManager.shared.activeProfile?.name ?? "Agor")
        .refreshable {
            await viewModel.refresh()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                appViewModel: appViewModel,
                socketService: socketService,
                onLogout: onLogout,
                onServerSwitch: onServerSwitch
            )
        }
        .sheet(item: $fileBrowserTarget) { target in
            FileBrowserView(viewModel: FileBrowserViewModel(
                worktreeId: target.id,
                socketService: socketService
            ))
        }
        .overlay {
            if viewModel.isLoading && viewModel.boardNodes.isEmpty {
                ProgressView("Loading...")
            } else if let error = viewModel.error, viewModel.boardNodes.isEmpty {
                ContentUnavailableView {
                    Label("Connection Error", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        Task { await viewModel.refresh() }
                    }
                }
            } else if viewModel.boardNodes.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(
                    "No Boards",
                    systemImage: "rectangle.on.rectangle.slash",
                    description: Text("Create a board in Agor to get started")
                )
            }
        }
    }
}

// MARK: - Important Session Row

private struct ImportantSessionRow: View {
    let session: Session
    let isFavorite: Bool
    let boardName: String?
    let worktreeName: String?
    let boardIcon: String?

    var body: some View {
        HStack(spacing: 10) {
            if let boardIcon {
                Text(boardIcon)
                    .font(.title3)
            } else {
                AgentIcon(agenticTool: session.agenticTool, size: 24)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(.subheadline)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    StatusBadge(status: session.status)

                    if session.isPlanMode {
                        Text("Plan")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.purple.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.purple)
                    }

                    Text(session.lastUpdated.relativeTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let boardName, let worktreeName {
                    Text("\(boardName) · \(worktreeName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                if session.readyForPrompt == true {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.blue)
                }
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Attention Session Row

private struct AttentionSessionRow: View {
    let session: Session
    let boardIcon: String?

    var body: some View {
        HStack(spacing: 10) {
            if let boardIcon {
                Text(boardIcon)
                    .font(.title3)
            } else {
                AgentIcon(agenticTool: session.agenticTool, size: 24)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(.subheadline)
                    .lineLimit(1)

                StatusBadge(status: session.status)
            }

            Spacer()

            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Favorite Context Menu Button

private struct FavoriteButton: View {
    let sessionId: String
    let viewModel: NavigationViewModel

    var body: some View {
        let isFav = viewModel.favoriteSessionIds.contains(sessionId)
        Button {
            viewModel.toggleFavorite(sessionId)
        } label: {
            Label(
                isFav ? "Remove from Favorites" : "Add to Favorites",
                systemImage: isFav ? "star.slash" : "star"
            )
        }
    }
}

// MARK: - Archive Context Menu Button

private struct ArchiveButton: View {
    let sessionId: String
    let viewModel: NavigationViewModel

    var body: some View {
        Button(role: .destructive) {
            Task { await viewModel.archiveSession(sessionId) }
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
    }
}

// MARK: - Browse Files Context Menu Button

private struct BrowseFilesButton: View {
    let worktreeId: String
    @Binding var target: FileBrowserTarget?

    var body: some View {
        Button {
            target = FileBrowserTarget(id: worktreeId)
        } label: {
            Label("Browse Files", systemImage: "folder")
        }
    }
}

// MARK: - Clean & Reset Context Menu Button

private struct CleanAndResetButton: View {
    let session: Session
    let viewModel: NavigationViewModel
    @Binding var selectedSessionId: String?

    var body: some View {
        Button(role: .destructive) {
            Task {
                await cleanAndReset()
            }
        } label: {
            Label("Clean & Reset", systemImage: "arrow.counterclockwise")
        }
    }

    private func cleanAndReset() async {
        // 1. Archive the current session
        await viewModel.archiveSession(session.sessionId)

        // 2. Create a new session on the same worktree
        struct CreateSessionBody: Codable {
            let worktreeId: String
            let agenticTool: String
            let status: String
            var title: String?

            enum CodingKeys: String, CodingKey {
                case worktreeId = "worktree_id"
                case agenticTool = "agentic_tool"
                case status
                case title
            }
        }

        do {
            let body = CreateSessionBody(
                worktreeId: session.worktreeId,
                agenticTool: session.agenticTool.rawValue,
                status: "idle",
                title: session.title
            )
            let newSession: Session = try await viewModel.client.post("/sessions", body: body)
            selectedSessionId = newSession.sessionId
        } catch {
            // Session creation failed — still refresh to show archived state
        }

        // 3. Refresh sidebar
        await viewModel.refresh()
    }
}

// MARK: - Worktree Section (expandable)

private struct WorktreeSection: View {
    let worktreeNode: WorktreeNode
    let viewModel: NavigationViewModel
    let socketService: SocketService
    @Binding var selectedSessionId: String?
    @State private var showFileBrowser = false
    @State private var sessionFileBrowserWorktreeId: String?
    @State private var showNewSessionAlert = false
    @State private var newSessionName = ""

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { worktreeNode.isExpanded },
            set: {
                worktreeNode.isExpanded = $0
                viewModel.setWorktreeExpanded(worktreeNode.worktree.worktreeId, expanded: $0)
                if $0 {
                    Task { await viewModel.loadSessions(for: worktreeNode) }
                }
            }
        )) {
            if worktreeNode.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if worktreeNode.sessions.isEmpty {
                Text("No sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(worktreeNode.sessions) { session in
                    NavigationLink(value: session.sessionId) {
                        SessionRow(session: session)
                    }
                    .contextMenu {
                        FavoriteButton(sessionId: session.sessionId, viewModel: viewModel)
                        Button {
                            sessionFileBrowserWorktreeId = session.worktreeId
                        } label: {
                            Label("Browse Files", systemImage: "folder")
                        }
                        Divider()
                        CleanAndResetButton(session: session, viewModel: viewModel, selectedSessionId: $selectedSessionId)
                        ArchiveButton(sessionId: session.sessionId, viewModel: viewModel)
                    }
                }
            }
        } label: {
            WorktreeRow(
                worktree: worktreeNode.worktree,
                repoName: worktreeNode.repoName,
                attentionCount: worktreeNode.attentionCount
            )
            .contextMenu {
                Button {
                    newSessionName = ""
                    showNewSessionAlert = true
                } label: {
                    Label("New Session", systemImage: "plus.bubble")
                }
                Button {
                    showFileBrowser = true
                } label: {
                    Label("Browse Files", systemImage: "folder")
                }
            }
        }
        .selectionDisabled()
        .sheet(isPresented: $showFileBrowser) {
            FileBrowserView(viewModel: FileBrowserViewModel(
                worktreeId: worktreeNode.worktree.worktreeId,
                socketService: socketService
            ))
        }
        .sheet(item: Binding(
            get: { sessionFileBrowserWorktreeId.map { FileBrowserTarget(id: $0) } },
            set: { sessionFileBrowserWorktreeId = $0?.id }
        )) { target in
            FileBrowserView(viewModel: FileBrowserViewModel(
                worktreeId: target.id,
                socketService: socketService
            ))
        }
        .alert("New Session", isPresented: $showNewSessionAlert) {
            TextField("Session name", text: $newSessionName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    await createSession(
                        worktreeId: worktreeNode.worktree.worktreeId,
                        name: name.isEmpty ? nil : name
                    )
                }
            }
        } message: {
            Text("Enter a name for the new session on this worktree.")
        }
    }

    private func createSession(worktreeId: String, name: String?) async {
        struct CreateSessionBody: Codable {
            let worktreeId: String
            let agenticTool: String
            let status: String
            var title: String?
            enum CodingKeys: String, CodingKey {
                case worktreeId = "worktree_id"
                case agenticTool = "agentic_tool"
                case status
                case title
            }
        }
        do {
            let body = CreateSessionBody(
                worktreeId: worktreeId,
                agenticTool: "claude-code",
                status: "idle",
                title: name
            )
            let newSession: Session = try await viewModel.client.post("/sessions", body: body)
            selectedSessionId = newSession.sessionId
            await viewModel.refresh()
        } catch {
            // Session creation failed — non-fatal
        }
    }
}
