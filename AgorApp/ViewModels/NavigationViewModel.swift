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

    // Sessions needing attention (across all boards)
    var attentionSessions: [Session] {
        boardNodes.flatMap { board in
            board.worktrees.flatMap { wt in
                wt.sessions.filter(\.status.needsAttention)
            }
        }
    }

    private let client: AgorClient
    private let socketService: SocketService

    // MARK: - Expansion Persistence

    private static let collapsedBoardsKey = "agor.collapsedBoardIds"
    private static let collapsedWorktreesKey = "agor.collapsedWorktreeIds"

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

    init(client: AgorClient, socketService: SocketService) {
        self.client = client
        self.socketService = socketService
        setupSocketHandlers()
    }

    // MARK: - Load Data

    func loadBoards() async {
        isLoading = true
        error = nil
        do {
            let response: PaginatedResponse<Board> = try await client.getPaginated("/boards", query: ["$limit": "50"])
            boardNodes = response.data.map { BoardNode(board: $0) }

            // Auto-expand and load all boards' worktrees
            for node in boardNodes {
                await loadWorktrees(for: node)
            }

            // Fetch repo names and apply to all worktree nodes
            await loadRepoNames()
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
            // Non-fatal — repo names are display-only
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

            // Auto-load sessions for all worktrees
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
                    wt.sessions[idx] = session
                    return
                }
            }
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
