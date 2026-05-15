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
    let chatVM: ChatViewModel
    let onLogout: () -> Void
    let onServerSwitch: ((ServerProfile) -> Void)?
    var onClearCache: (() -> Void)?

    @State private var showSettings = false
    @State private var fileBrowserTarget: FileBrowserTarget?
    @State private var searchText = ""

    var body: some View {
        List(selection: $selectedSessionId) {
            // Server tab bar
            Section {
                HStack(spacing: 8) {
                    ServerTabBar(
                        profiles: ServerProfileManager.shared.profiles,
                        activeProfileId: ServerProfileManager.shared.activeProfileId,
                        connectionState: socketService.connectionState,
                        onSelect: { profile in onServerSwitch?(profile) }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(.secondary.opacity(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                .selectionDisabled()
            }

            // Search bar
            Section {
                SessionSearchBar(text: $searchText)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 4, trailing: 8))
                    .selectionDisabled()
            }

            if searchText.isEmpty {
                if !viewModel.favoriteSessions.isEmpty {
                    Section {
                        ForEach(viewModel.favoriteSessions) { session in
                            let ctx = viewModel.findContext(for: session)
                            NavigationLink(value: session.sessionId) {
                                ImportantSessionRow(
                                    session: session,
                                    isFavorite: true,
                                    boardName: ctx?.boardName,
                                    worktreeName: ctx?.worktreeName,
                                    boardIcon: ctx?.boardIcon
                                )
                            }
                            .contextMenu {
                                FavoriteButton(sessionId: session.sessionId, viewModel: viewModel)
                                BrowseFilesButton(worktreeId: session.worktreeId, target: $fileBrowserTarget)
                                Divider()
                                CleanAndResetButton(session: session, viewModel: viewModel, socketService: socketService, selectedSessionId: $selectedSessionId)
                                ArchiveButton(sessionId: session.sessionId, viewModel: viewModel)
                            }
                        }
                    } header: {
                        Label("Favorites", systemImage: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                }

                // Needs Attention Section
                if !viewModel.attentionSessions.isEmpty {
                    Section {
                        ForEach(viewModel.attentionSessions) { session in
                            let ctx = viewModel.findContext(for: session)
                            NavigationLink(value: session.sessionId) {
                                AttentionSessionRow(session: session, boardIcon: ctx?.boardIcon)
                            }
                            .contextMenu {
                                FavoriteButton(sessionId: session.sessionId, viewModel: viewModel)
                                BrowseFilesButton(worktreeId: session.worktreeId, target: $fileBrowserTarget)
                                Divider()
                                CleanAndResetButton(session: session, viewModel: viewModel, socketService: socketService, selectedSessionId: $selectedSessionId)
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
                            let ctx = viewModel.findContext(for: session)
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
                                CleanAndResetButton(session: session, viewModel: viewModel, socketService: socketService, selectedSessionId: $selectedSessionId)
                                ArchiveButton(sessionId: session.sessionId, viewModel: viewModel)
                            }
                        }
                    } header: {
                        Label("Important", systemImage: "sparkles")
                            .foregroundStyle(.primary)
                    }
                }

                // Boards — Button header instead of DisclosureGroup so taps never leak to List selection
                ForEach(viewModel.boardNodes) { boardNode in
                    Section {
                        Button {
                            let expanding = !boardNode.isExpanded
                            boardNode.isExpanded = expanding
                            viewModel.setBoardExpanded(boardNode.board.boardId, expanded: expanding)
                            if expanding {
                                Task { await viewModel.loadWorktrees(for: boardNode) }
                            }
                        } label: {
                            HStack {
                                BoardRow(board: boardNode.board, attentionCount: boardNode.attentionCount)
                                Image(systemName: "chevron.right")
                                    .rotationEffect(.degrees(boardNode.isExpanded ? 90 : 0))
                                    .animation(.easeInOut(duration: 0.2), value: boardNode.isExpanded)
                                    .foregroundStyle(.secondary)
                                    .font(.caption.weight(.semibold))
                            }
                        }
                        .buttonStyle(.plain)
                        .selectionDisabled()

                        if boardNode.isExpanded {
                            if boardNode.isLoading {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .selectionDisabled()
                            } else {
                                ForEach(boardNode.worktrees) { wtNode in
                                    WorktreeSection(
                                        worktreeNode: wtNode,
                                        viewModel: viewModel,
                                        socketService: socketService,
                                        currentUser: appViewModel.currentUser,
                                        selectedSessionId: $selectedSessionId
                                    )
                                }
                            }
                        }
                    }
                }
            } else {
                // Search results
                let results = searchResults
                Section {
                    if results.isEmpty {
                        Text("No sessions match \"\(searchText)\"")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.clear)
                            .selectionDisabled()
                    } else {
                        ForEach(results) { session in
                            let ctx = viewModel.findContext(for: session)
                            Button {
                                viewModel.revealSession(session)
                                searchText = ""
                                selectedSessionId = session.sessionId
                            } label: {
                                ImportantSessionRow(
                                    session: session,
                                    isFavorite: viewModel.favoriteSessionIds.contains(session.sessionId),
                                    boardName: ctx?.boardName,
                                    worktreeName: ctx?.worktreeName,
                                    boardIcon: ctx?.boardIcon
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                FavoriteButton(sessionId: session.sessionId, viewModel: viewModel)
                                BrowseFilesButton(worktreeId: session.worktreeId, target: $fileBrowserTarget)
                                Divider()
                                CleanAndResetButton(session: session, viewModel: viewModel, socketService: socketService, selectedSessionId: $selectedSessionId)
                                ArchiveButton(sessionId: session.sessionId, viewModel: viewModel)
                            }
                        }
                    }
                } header: {
                    Text(results.isEmpty ? "Results" : "\(results.count) session\(results.count == 1 ? "" : "s")")
                }
            }

        }
        .listStyle(.sidebar)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await viewModel.refresh()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(
                appViewModel: appViewModel,
                socketService: socketService,
                chatVM: chatVM,
                onLogout: onLogout,
                onServerSwitch: onServerSwitch,
                onClearCache: onClearCache
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
                    Text(verbatim: error)
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

    // MARK: - Search

    private var searchResults: [Session] {
        let query = searchText.lowercased()
        let all = viewModel.boardNodes.flatMap { $0.worktrees.flatMap { $0.sessions } }
            + viewModel.attentionSessions
            + viewModel.importantSessions
        var seen = Set<String>()
        return all.filter { session in
            guard seen.insert(session.sessionId).inserted else { return false }
            return session.displayTitle.lowercased().contains(query)
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
                Text(verbatim: session.displayTitle)
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
                    Text(verbatim: "\(boardName) · \(worktreeName)")
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
                Text(verbatim: session.displayTitle)
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
    let socketService: SocketService
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
        AppLogger.shared.log("[Sidebar] cleanAndReset session=\(String(session.sessionId.prefix(8)))", level: .info, category: "Nav")

        // 1. Archive the current session
        await viewModel.archiveSession(session.sessionId)

        // 2. Create a new session on the same worktree via Socket.IO
        do {
            var body: [String: Any] = [
                "worktree_id": session.worktreeId,
                "agentic_tool": session.agenticTool.rawValue,
                "status": "idle"
            ]
            if let title = session.title, !title.isEmpty {
                body["title"] = title
            }
            if let unixUsername = session.unixUsername {
                body["unix_username"] = unixUsername
            }
            let newSession: Session = try await socketService.serviceCreate(
                service: "sessions",
                data: body
            )
            AppLogger.shared.log("[Sidebar] cleanAndReset created new session \(String(newSession.sessionId.prefix(8)))", level: .info, category: "Nav")
            selectedSessionId = newSession.sessionId
        } catch {
            AppLogger.shared.log("[Sidebar] cleanAndReset create ERROR: \(error)", level: .error, category: "Nav")
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
    var currentUser: User?
    @Binding var selectedSessionId: String?
    @State private var showFileBrowser = false
    @State private var sessionFileBrowserWorktreeId: String?
    @State private var showNewSessionSheet = false
    @State private var newSessionName = ""
    @State private var newSessionTool: AgenticToolName = .claudeCode

    var body: some View {
        // Worktree header — Button fully captures tap, never leaks to List selection
        Button {
            let expanding = !worktreeNode.isExpanded
            worktreeNode.isExpanded = expanding
            viewModel.setWorktreeExpanded(worktreeNode.worktree.worktreeId, expanded: expanding)
            if expanding { Task { await viewModel.loadSessions(for: worktreeNode) } }
        } label: {
            HStack {
                worktreeLabel
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(worktreeNode.isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: worktreeNode.isExpanded)
                    .foregroundStyle(.secondary)
                    .font(.caption.weight(.semibold))
            }
        }
        .buttonStyle(.plain)
        .selectionDisabled()
        .sheet(isPresented: $showFileBrowser) {
            FileBrowserView(viewModel: FileBrowserViewModel(worktreeId: worktreeNode.worktree.worktreeId, socketService: socketService))
        }
        .sheet(item: Binding(
            get: { sessionFileBrowserWorktreeId.map { FileBrowserTarget(id: $0) } },
            set: { sessionFileBrowserWorktreeId = $0?.id }
        )) { target in
            FileBrowserView(viewModel: FileBrowserViewModel(worktreeId: target.id, socketService: socketService))
        }
        .sheet(isPresented: $showNewSessionSheet) {
            NewSessionSheet(
                worktreeName: worktreeNode.worktree.name,
                sessionName: $newSessionName,
                agenticTool: $newSessionTool,
                onCreate: {
                    let name = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
                    showNewSessionSheet = false
                    Task { await createSession(worktreeId: worktreeNode.worktree.worktreeId, name: name.isEmpty ? nil : name, tool: newSessionTool) }
                }
            )
        }

        if worktreeNode.isExpanded {
            sessionsList
        }
    }

    @ViewBuilder private var sessionsList: some View {
        if worktreeNode.isLoading {
            ProgressView().frame(maxWidth: .infinity)
        } else {
            if worktreeNode.sessions.isEmpty {
                Text("No sessions").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(viewModel.orderedSessionsForDisplay(worktreeNode.sessions)) { session in
                NavigationLink(value: session.sessionId) {
                    SessionRow(session: session)
                }
                .contextMenu {
                    FavoriteButton(sessionId: session.sessionId, viewModel: viewModel)
                    Button { sessionFileBrowserWorktreeId = session.worktreeId } label: {
                        Label("Browse Files", systemImage: "folder")
                    }
                    Divider()
                    CleanAndResetButton(session: session, viewModel: viewModel, socketService: socketService, selectedSessionId: $selectedSessionId)
                    ArchiveButton(sessionId: session.sessionId, viewModel: viewModel)
                }
            }
            Button { newSessionName = ""; newSessionTool = .claudeCode; showNewSessionSheet = true } label: {
                Label("New Session", systemImage: "plus.bubble")
                    .font(.caption).foregroundStyle(Color.accentColor)
            }
        }
    }

    private var worktreeLabel: some View {
        WorktreeRow(worktree: worktreeNode.worktree, repoName: worktreeNode.repoName, attentionCount: worktreeNode.attentionCount)
            .contextMenu {
                Button { newSessionName = ""; newSessionTool = .claudeCode; showNewSessionSheet = true } label: {
                    Label("New Session", systemImage: "plus.bubble")
                }
                Button { showFileBrowser = true } label: {
                    Label("Browse Files", systemImage: "folder")
                }
            }
    }

    private func createSession(worktreeId: String, name: String?, tool: AgenticToolName = .claudeCode) async {
        AppLogger.shared.log("[Sidebar] createSession worktreeId=\(String(worktreeId.prefix(8))) tool=\(tool.rawValue) name=\(name ?? "<nil>")", level: .info, category: "Nav")
        do {
            var body: [String: Any] = [
                "worktree_id": worktreeId,
                "agentic_tool": tool.rawValue,
                "status": "idle"
            ]
            if let name, !name.isEmpty {
                body["title"] = name
            }
            if let unixUsername = currentUser?.unixUsername {
                body["unix_username"] = unixUsername
            }
            let newSession: Session = try await socketService.serviceCreate(
                service: "sessions",
                data: body
            )
            AppLogger.shared.log("[Sidebar] createSession OK: \(String(newSession.sessionId.prefix(8)))", level: .info, category: "Nav")
            selectedSessionId = newSession.sessionId
            await viewModel.refresh()
        } catch {
            AppLogger.shared.log("[Sidebar] createSession ERROR: \(error)", level: .error, category: "Nav")
        }
    }
}

// MARK: - New Session Sheet

private struct NewSessionSheet: View {
    let worktreeName: String
    @Binding var sessionName: String
    @Binding var agenticTool: AgenticToolName
    let onCreate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Session Name") {
                    TextField("Optional name", text: $sessionName)
                        .autocorrectionDisabled()
                }
                Section("Agent") {
                    ForEach(AgenticToolName.allCases, id: \.self) { tool in
                        Button {
                            agenticTool = tool
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: tool.iconName)
                                    .frame(width: 20)
                                    .foregroundStyle(agenticTool == tool ? .primary : .secondary)
                                Text(tool.displayLabel)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if agenticTool == tool {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("New Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: onCreate)
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Session Search Bar

private struct SessionSearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
            TextField("Filter sessions…", text: $text)
                .font(.subheadline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Server Tab Bar

private struct ServerTabBar: View {
    let profiles: [ServerProfile]
    let activeProfileId: UUID?
    let connectionState: ConnectionState
    let onSelect: (ServerProfile) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(profiles) { profile in
                    let isActive = profile.id == activeProfileId
                    Button {
                        guard !isActive else { return }
                        onSelect(profile)
                    } label: {
                        HStack(spacing: 4) {
                            if isActive {
                                Circle()
                                    .fill(dotColor)
                                    .frame(width: 6, height: 6)
                            }
                            Text(profile.name)
                                .font(.caption.weight(isActive ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            isActive ? Color.accentColor : Color.secondary.opacity(0.15),
                            in: Capsule()
                        )
                        .foregroundStyle(isActive ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var dotColor: Color {
        switch connectionState {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .disconnected: .red
        }
    }
}
