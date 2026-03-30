import Foundation

// MARK: - Board Node (with children)

@Observable
final class BoardNode: Identifiable {
    let board: Board
    var worktrees: [WorktreeNode] = []
    var isExpanded = false
    var isLoading = false

    var id: String { board.boardId }

    var attentionCount: Int {
        worktrees.reduce(0) { $0 + $1.attentionCount }
    }

    init(board: Board) {
        self.board = board
    }
}

@Observable
final class WorktreeNode: Identifiable {
    let worktree: Worktree
    var sessions: [Session] = []
    var repoName: String?
    var isExpanded = false
    var isLoading = false

    var id: String { worktree.worktreeId }

    var attentionCount: Int {
        sessions.filter(\.status.needsAttention).count
    }

    init(worktree: Worktree) {
        self.worktree = worktree
    }
}

// MARK: - Navigation ViewModel

@Observable
final class NavigationViewModel {
    var boardNodes: [BoardNode] = []
    var isLoading = false
    var error: String?

    // Stored so @Observable tracks changes and computed sections recompute reactively
    var favoriteSessionIds: Set<String> = []

    // Sessions needing attention (awaiting permission or input)
    var attentionSessions: [Session] {
        boardNodes.flatMap { $0.worktrees.flatMap { $0.sessions.filter { $0.status.needsAttention && !$0.isScheduled } } }
    }

    // Important sessions: ready-for-prompt + running + favorites + 3 most recent
    // Excludes attention sessions (they have their own section above)
    var importantSessions: [Session] {
        let all = boardNodes.flatMap { $0.worktrees.flatMap(\.sessions) }
        let attentionIds = Set(attentionSessions.map(\.sessionId))
        var seen = Set<String>()
        var result: [Session] = []

        func add(_ session: Session) {
            guard !seen.contains(session.sessionId),
                  !attentionIds.contains(session.sessionId) else { return }
            // Exclude untitled/auto-generated sessions unless favorited
            guard session.hasExplicitTitle || favoriteSessionIds.contains(session.sessionId) else { return }
            seen.insert(session.sessionId)
            result.append(session)
        }

        // 1. Ready for prompt — agent finished, user hasn't reviewed yet
        for s in all where s.readyForPrompt == true { add(s) }

        // 2. Running sessions
        for s in all where s.status == .running { add(s) }

        // 3. Favorites (local)
        for s in all where favoriteSessionIds.contains(s.sessionId) { add(s) }

        // 4. Last 3 recently updated (not already included)
        let recent = all
            .filter { !seen.contains($0.sessionId) && !attentionIds.contains($0.sessionId) }
            .sorted { $0.lastUpdated > $1.lastUpdated }
            .prefix(3)
        for s in recent { add(s) }

        return result
    }

    let client: AgorClient
    private let socketService: SocketService
    private var pollingTimer: Timer?

    // MARK: - Persistence

    private static let collapsedBoardsKey = "agor.collapsedBoardIds"
    private static let collapsedWorktreesKey = "agor.collapsedWorktreeIds"
    private static let favoritesKey = "agor.favoriteSessionIds"

    private var collapsedBoardIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.collapsedBoardsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.collapsedBoardsKey) }
    }

    private var collapsedWorktreeIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.collapsedWorktreesKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.collapsedWorktreesKey) }
    }

    func setBoardExpanded(_ boardId: String, expanded: Bool) {
        var collapsed = collapsedBoardIds
        if expanded { collapsed.remove(boardId) } else { collapsed.insert(boardId) }
        collapsedBoardIds = collapsed
    }

    func setWorktreeExpanded(_ worktreeId: String, expanded: Bool) {
        var collapsed = collapsedWorktreeIds
        if expanded { collapsed.remove(worktreeId) } else { collapsed.insert(worktreeId) }
        collapsedWorktreeIds = collapsed
    }

    func toggleFavorite(_ sessionId: String) {
        if favoriteSessionIds.contains(sessionId) {
            favoriteSessionIds.remove(sessionId)
        } else {
            favoriteSessionIds.insert(sessionId)
        }
        UserDefaults.standard.set(Array(favoriteSessionIds), forKey: Self.favoritesKey)
    }

    init(client: AgorClient, socketService: SocketService) {
        self.client = client
        self.socketService = socketService
        // Load persisted favorites into stored property so @Observable tracks it
        self.favoriteSessionIds = Set(UserDefaults.standard.stringArray(forKey: Self.favoritesKey) ?? [])
        setupSocketHandlers()
    }

    // MARK: - Load Data

    func loadBoards() async {
        isLoading = true
        error = nil

        // Load from cache first for instant display
        if boardNodes.isEmpty, let cached = SidebarCache.load() {
            boardNodes = cached
            // Restore expansion state from persisted preferences
            for node in boardNodes {
                node.isExpanded = !collapsedBoardIds.contains(node.board.boardId)
                for wt in node.worktrees {
                    wt.isExpanded = !collapsedWorktreeIds.contains(wt.worktree.worktreeId)
                }
            }
            isLoading = false
        }

        do {
            let response: PaginatedResponse<Board> = try await client.getPaginated("/boards", query: ["$limit": "50"])
            boardNodes = response.data.map { BoardNode(board: $0) }

            for node in boardNodes {
                await loadWorktrees(for: node)
            }

            await loadRepoNames()

            // Save to cache after successful load
            SidebarCache.save(boardNodes: boardNodes)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func loadRepoNames() async {
        do {
            let response: PaginatedResponse<Repo> = try await client.getPaginated("/repos", query: ["$limit": "100"])
            let lookup = Dictionary(uniqueKeysWithValues: response.data.map { ($0.repoId, $0.name) })
            for board in boardNodes {
                for wt in board.worktrees {
                    wt.repoName = lookup[wt.worktree.repoId]
                }
            }
        } catch {
            // Non-fatal
        }
    }

    func loadWorktrees(for boardNode: BoardNode) async {
        boardNode.isLoading = true
        do {
            let response: PaginatedResponse<Worktree> = try await client.getPaginated(
                "/worktrees",
                query: [
                    "board_id": boardNode.board.boardId,
                    "$limit": "100",
                    "archived": "false",
                ]
            )
            boardNode.worktrees = response.data.map { WorktreeNode(worktree: $0) }
            boardNode.isExpanded = !collapsedBoardIds.contains(boardNode.board.boardId)

            for wt in boardNode.worktrees {
                await loadSessions(for: wt)
            }
        } catch {
            // Non-fatal
        }
        boardNode.isLoading = false
    }

    func loadSessions(for worktreeNode: WorktreeNode) async {
        worktreeNode.isLoading = true
        do {
            let response: PaginatedResponse<Session> = try await client.getPaginated(
                "/sessions",
                query: [
                    "worktree_id": worktreeNode.worktree.worktreeId,
                    "$limit": "50",
                    "$sort[last_updated]": "-1",
                    "archived": "false",
                ]
            )
            worktreeNode.sessions = response.data
            worktreeNode.isExpanded = !collapsedWorktreeIds.contains(worktreeNode.worktree.worktreeId)
        } catch {
            // Non-fatal
        }
        worktreeNode.isLoading = false
    }

    func refresh() async {
        await loadBoards()
    }

    func startPolling() {
        stopPolling()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshExpandedNodes() }
        }
    }

    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func refreshExpandedNodes() async {
        for board in boardNodes where board.isExpanded {
            for wt in board.worktrees where wt.isExpanded {
                await loadSessions(for: wt)
            }
        }
    }

    // MARK: - Socket Handlers

    private func setupSocketHandlers() {
        socketService.onSessionPatched { [weak self] session in
            self?.handleSessionUpdate(session)
        }
    }

    private func handleSessionUpdate(_ session: Session) {
        for board in boardNodes {
            for wt in board.worktrees {
                if let idx = wt.sessions.firstIndex(where: { $0.sessionId == session.sessionId }) {
                    if session.archived == true {
                        wt.sessions.remove(at: idx)
                    } else {
                        wt.sessions[idx] = session
                    }
                    return
                }
            }
        }
    }

    // MARK: - Archive Session

    func archiveSession(_ sessionId: String) async {
        do {
            struct ArchiveBody: Codable { let archived: Bool }
            let _: Session = try await client.patch("/sessions/\(sessionId)", body: ArchiveBody(archived: true))
            for board in boardNodes {
                for wt in board.worktrees {
                    wt.sessions.removeAll { $0.sessionId == sessionId }
                }
            }
        } catch {
            // Non-fatal
        }
    }

    // MARK: - Lookup

    func findSession(_ sessionId: String) -> Session? {
        for board in boardNodes {
            for wt in board.worktrees {
                if let session = wt.sessions.first(where: { $0.sessionId == sessionId }) {
                    return session
                }
            }
        }
        return nil
    }

    func findContext(for sessionId: String) -> (boardName: String, worktreeName: String, boardIcon: String)? {
        for board in boardNodes {
            for wt in board.worktrees {
                if wt.sessions.contains(where: { $0.sessionId == sessionId }) {
                    return (board.board.name, wt.worktree.displayName, board.board.displayIcon)
                }
            }
        }
        return nil
    }

    func findWorktree(for sessionId: String) -> Worktree? {
        for board in boardNodes {
            for wt in board.worktrees {
                if wt.sessions.contains(where: { $0.sessionId == sessionId }) {
                    return wt.worktree
                }
            }
        }
        return nil
    }
}
