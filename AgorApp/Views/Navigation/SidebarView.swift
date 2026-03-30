import SwiftUI

struct SidebarView: View {
    let viewModel: NavigationViewModel
    @Binding var selectedSessionId: String?
    let appViewModel: AppViewModel
    let socketService: SocketService
    let onLogout: () -> Void
    @State private var showSettings = false

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
                            Divider()
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
                            Divider()
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
        .navigationTitle("Agor")
        .refreshable {
            await viewModel.refresh()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                appViewModel: appViewModel,
                socketService: socketService,
                onLogout: onLogout
            )
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

// MARK: - Worktree Section (expandable)

private struct WorktreeSection: View {
    let worktreeNode: WorktreeNode
    let viewModel: NavigationViewModel
    @Binding var selectedSessionId: String?
    @State private var showFileBrowser = false

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
                        Divider()
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
        }
        .selectionDisabled()
        .contextMenu {
            Button {
                showFileBrowser = true
            } label: {
                Label("Browse Files", systemImage: "folder")
            }
        }
        .sheet(isPresented: $showFileBrowser) {
            FileBrowserView(viewModel: FileBrowserViewModel(
                worktreeId: worktreeNode.worktree.worktreeId,
                client: viewModel.client
            ))
        }
    }
}
