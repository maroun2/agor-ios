import Foundation
import WidgetKit

// MARK: - Board Node (with children)

@Observable
final class BoardNode: Identifiable {
    var board: Board
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
    var worktree: Worktree
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
@MainActor
final class NavigationViewModel {
    var boardNodes: [BoardNode] = []
    var isLoading = false
    var error: String?

    // Stored so @Observable tracks changes and computed sections recompute reactively
    var favoriteSessionIds: Set<String> = []

    /// Sessions for list presentation:
    /// favorites first, then most recently updated, preserving a stable order for ties.
    func orderedSessionsForDisplay(_ sessions: [Session]) -> [Session] {
        sessions.enumerated()
            .sorted { lhs, rhs in
                let lhsIsFavorite = favoriteSessionIds.contains(lhs.element.sessionId)
                let rhsIsFavorite = favoriteSessionIds.contains(rhs.element.sessionId)
                if lhsIsFavorite != rhsIsFavorite {
                    return lhsIsFavorite && !rhsIsFavorite
                }

                if lhs.element.lastUpdated != rhs.element.lastUpdated {
                    return lhs.element.lastUpdated > rhs.element.lastUpdated
                }

                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // Sessions needing attention (awaiting permission or input)
    var attentionSessions: [Session] {
        boardNodes.flatMap { $0.worktrees.flatMap { $0.sessions.filter { $0.status.needsAttention && !$0.isScheduled } } }
    }

    var favoriteSessions: [Session] {
        boardNodes
            .flatMap { $0.worktrees.flatMap(\.sessions) }
            .filter { favoriteSessionIds.contains($0.sessionId) && !$0.isScheduled }
            .sorted { $0.lastUpdated > $1.lastUpdated }
    }

    // Running sessions: status == .running, not attention, not scheduled
    var runningSessions: [Session] {
        let attentionIds = Set(attentionSessions.map(\.sessionId))
        return boardNodes
            .flatMap { $0.worktrees.flatMap(\.sessions) }
            .filter { $0.status == .running && !$0.isScheduled && !attentionIds.contains($0.sessionId) }
            .sorted { $0.lastUpdated > $1.lastUpdated }
    }

    // Finished sessions: readyForPrompt == true, not scheduled, not already in Running or Favorites
    var finishedSessions: [Session] {
        let runningIds = Set(runningSessions.map(\.sessionId))
        return boardNodes
            .flatMap { $0.worktrees.flatMap(\.sessions) }
            .filter {
                $0.readyForPrompt == true &&
                !$0.isScheduled &&
                !runningIds.contains($0.sessionId) &&
                !favoriteSessionIds.contains($0.sessionId)
            }
            .sorted { $0.lastUpdated > $1.lastUpdated }
    }

    // Important sessions: ready-for-prompt + running + 3 most recent
    // Excludes attention sessions (they have their own section above)
    var importantSessions: [Session] {
        let all = boardNodes.flatMap { $0.worktrees.flatMap(\.sessions) }
            .sorted { $0.lastUpdated > $1.lastUpdated }
        let attentionIds = Set(attentionSessions.map(\.sessionId))
        var seen = Set<String>()
        var result: [Session] = []

        func add(_ session: Session) {
            guard !seen.contains(session.sessionId),
                  !attentionIds.contains(session.sessionId),
                  !favoriteSessionIds.contains(session.sessionId) else { return }
            // Exclude untitled/auto-generated sessions unless favorited
            guard session.hasExplicitTitle || favoriteSessionIds.contains(session.sessionId) else { return }
            seen.insert(session.sessionId)
            result.append(session)
        }

        // 1. Ready for prompt — agent finished, user hasn't reviewed yet
        for s in all where s.readyForPrompt == true { add(s) }

        // 2. Running sessions
        for s in all where s.status == .running { add(s) }

        // 3. Last 3 recently updated (not already included)
        let recent = all
            .filter { !seen.contains($0.sessionId) && !attentionIds.contains($0.sessionId) }
            .prefix(3)
        for s in recent { add(s) }

        return result
    }

    let client: AgorClient
    private let socketService: SocketService
    private var pollingTimer: Timer?
    /// Guards against concurrent loadBoards() calls (e.g. startup task + health-check reconnect).
    private var isLoadingBoards = false

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
        guard !isLoadingBoards else {
            AppLogger.shared.log("[Nav] loadBoards: already in flight — skipping duplicate call", level: .debug, category: "Nav")
            return
        }
        isLoadingBoards = true
        defer { isLoadingBoards = false }
        isLoading = true
        error = nil

        // Load from cache first for instant display
        if boardNodes.isEmpty, let cached = SidebarCache.load() {
            AppLogger.shared.log("[Nav] cache: loaded \(cached.count) boards from disk", level: .debug, category: "Nav")
            boardNodes = cached
            // Restore expansion state from persisted preferences
            for node in boardNodes {
                node.isExpanded = !collapsedBoardIds.contains(node.board.boardId)
                for wt in node.worktrees {
                    wt.isExpanded = !collapsedWorktreeIds.contains(wt.worktree.worktreeId)
                }
            }
            isLoading = false
        } else if boardNodes.isEmpty {
            AppLogger.shared.log("[Nav] cache: no cached data", level: .debug, category: "Nav")
        }

        do {
            let response: PaginatedResponse<Board> = try await client.getPaginated("/boards", query: ["$limit": "50"])

            // Incremental merge: reuse existing BoardNode objects to preserve worktrees/expansion state
            let existingByBoardId = Dictionary(uniqueKeysWithValues: boardNodes.map { ($0.board.boardId, $0) })
            var mergedNodes: [BoardNode] = []
            var newCount = 0
            var existingCount = 0
            for board in response.data {
                if let existing = existingByBoardId[board.boardId] {
                    existing.board = board
                    mergedNodes.append(existing)
                    existingCount += 1
                } else {
                    mergedNodes.append(BoardNode(board: board))
                    newCount += 1
                }
            }
            let removedCount = existingByBoardId.count - existingCount
            boardNodes = mergedNodes

            AppLogger.shared.log("[Nav] loadBoards: \(mergedNodes.count) boards (\(newCount) new, \(existingCount) existing, \(removedCount) removed)", level: .debug, category: "Nav")

            // Load ALL sessions in ONE call.
            // Server's worktree_id filter is not implemented — returns all sessions regardless.
            // Matching web UI approach: fetch everything at once, group client-side.
            let sessionsByWorktreeId = await fetchAllSessions()
            await loadRepoNames()

            // Load worktrees per board (board_id filter works correctly on server)
            for node in boardNodes {
                await loadWorktrees(for: node, sessionsByWorktreeId: sessionsByWorktreeId)
            }

            // Save to cache after successful load
            SidebarCache.save(boardNodes: boardNodes)
            AppLogger.shared.log("[Nav] cache: saved \(boardNodes.count) boards to disk", level: .debug, category: "Nav")

            // Refresh widget data with latest favorites
            await refreshWidgetData()
        } catch {
            self.error = error.localizedDescription
            AppLogger.shared.log("[Nav] loadBoards failed: \(error.localizedDescription)", level: .error, category: "Nav")
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
            AppLogger.shared.log("[Nav] loadRepoNames failed: \(error.localizedDescription)", level: .error, category: "Nav")
        }
    }

    /// Fetch ALL sessions in a single API call and group them by worktreeId.
    /// The server's worktree_id and archived filters are not applied at DB level —
    /// they filter in-memory after a full table scan, making the query equally slow.
    /// Fetch everything and filter archived sessions client-side instead.
    @discardableResult
    private func fetchAllSessions() async -> [String: [Session]] {
        do {
            let response: PaginatedResponse<Session> = try await client.getPaginated(
                "/sessions",
                query: [
                    "$limit": "10000",
                    "$sort[last_updated]": "-1",
                ]
            )
            var grouped: [String: [Session]] = [:]
            for session in response.data where session.archived != true {
                grouped[session.worktreeId, default: []].append(session)
            }
            AppLogger.shared.log("[Nav] fetchAllSessions: \(response.data.count) total, \(grouped.values.reduce(0) { $0 + $1.count }) active across \(grouped.count) worktrees", level: .debug, category: "Nav")
            return grouped
        } catch {
            AppLogger.shared.log("[Nav] fetchAllSessions failed: \(error.localizedDescription)", level: .error, category: "Nav")
            return [:]
        }
    }

    /// Assign pre-fetched sessions to all WorktreeNodes.
    private func assignSessions(_ sessionsByWorktreeId: [String: [Session]]) {
        for board in boardNodes {
            for wt in board.worktrees {
                let sessions = orderedSessionsForDisplay(sessionsByWorktreeId[wt.worktree.worktreeId] ?? [])
                let newIds = Set(sessions.map(\.sessionId))
                let oldIds = Set(wt.sessions.map(\.sessionId))
                if oldIds != newIds || wt.sessions.count != sessions.count {
                    wt.sessions = sessions
                } else {
                    for (index, session) in sessions.enumerated() {
                        if index < wt.sessions.count,
                           wt.sessions[index].sessionId == session.sessionId,
                           wt.sessions[index] != session {
                            wt.sessions[index] = session
                        }
                    }
                }
                wt.isExpanded = !collapsedWorktreeIds.contains(wt.worktree.worktreeId)
            }
        }
    }

    func loadWorktrees(for boardNode: BoardNode, sessionsByWorktreeId: [String: [Session]]? = nil) async {
        boardNode.isLoading = true
        do {
            // v21 uses /branches, v19 uses /worktrees — try both
            let query = [
                "board_id": boardNode.board.boardId,
                "$limit": "100",
                "archived": "false",
            ]
            let response: PaginatedResponse<Worktree>
            do {
                response = try await client.getPaginated("/branches", query: query)
            } catch {
                // Fallback for v19 servers that still use /worktrees
                response = try await client.getPaginated("/worktrees", query: query)
            }
            // Incremental merge: reuse existing WorktreeNode objects to preserve sessions/expansion state
            let existingByWtId = Dictionary(uniqueKeysWithValues: boardNode.worktrees.map { ($0.worktree.worktreeId, $0) })
            var mergedWorktrees: [WorktreeNode] = []
            for worktree in response.data {
                if let existing = existingByWtId[worktree.worktreeId] {
                    existing.worktree = worktree
                    mergedWorktrees.append(existing)
                } else {
                    mergedWorktrees.append(WorktreeNode(worktree: worktree))
                }
            }
            boardNode.worktrees = mergedWorktrees
            boardNode.isExpanded = !collapsedBoardIds.contains(boardNode.board.boardId)

            let boardId = String(boardNode.board.boardId.prefix(8))
            AppLogger.shared.log("[Nav] loadWorktrees boardId=\(boardId): \(mergedWorktrees.count) worktrees", level: .debug, category: "Nav")

            // Assign pre-fetched sessions if available; otherwise skip (caller fetches separately)
            if let sessionsByWorktreeId {
                for wt in boardNode.worktrees {
                    let sessions = orderedSessionsForDisplay(sessionsByWorktreeId[wt.worktree.worktreeId] ?? [])
                    wt.sessions = sessions
                    wt.isExpanded = !collapsedWorktreeIds.contains(wt.worktree.worktreeId)
                }
            }
        } catch {
            let boardId = String(boardNode.board.boardId.prefix(8))
            AppLogger.shared.log("[Nav] loadWorktrees boardId=\(boardId) failed: \(error.localizedDescription)", level: .error, category: "Nav")
        }
        boardNode.isLoading = false
    }

    /// Refresh sessions for a specific worktree (triggered on expand).
    /// Fetches all sessions and assigns to the target worktree — one API call.
    func loadSessions(for worktreeNode: WorktreeNode) async {
        worktreeNode.isLoading = true
        let grouped = await fetchAllSessions()
        let sessions = orderedSessionsForDisplay(grouped[worktreeNode.worktree.worktreeId] ?? [])
        let newIds = Set(sessions.map(\.sessionId))
        let oldIds = Set(worktreeNode.sessions.map(\.sessionId))
        if oldIds != newIds || worktreeNode.sessions.count != sessions.count {
            worktreeNode.sessions = sessions
        } else {
            for (index, session) in sessions.enumerated() {
                if index < worktreeNode.sessions.count,
                   worktreeNode.sessions[index].sessionId == session.sessionId,
                   worktreeNode.sessions[index] != session {
                    worktreeNode.sessions[index] = session
                }
            }
        }
        worktreeNode.isExpanded = !collapsedWorktreeIds.contains(worktreeNode.worktree.worktreeId)
        worktreeNode.isLoading = false

        // Propagate the fresh session data to all other worktrees as a bonus
        assignSessions(grouped)
    }

    func refresh() async {
        await loadBoards()
    }

    func clearCache() {
        SidebarCache.clear()
        boardNodes = []
        UserDefaults.standard.removeObject(forKey: Self.collapsedBoardsKey)
        UserDefaults.standard.removeObject(forKey: Self.collapsedWorktreesKey)
        AppLogger.shared.log("[Nav] cache cleared", level: .info, category: "Nav")
    }

    func startPolling() {
        stopPolling()
        AppLogger.shared.log("[Nav] polling started (45s)", level: .info, category: "Nav")
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshExpandedNodes() }
        }
    }

    func stopPolling() {
        if pollingTimer != nil {
            AppLogger.shared.log("[Nav] polling stopped", level: .info, category: "Nav")
        }
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func refreshExpandedNodes() async {
        let expandedBoards = boardNodes.filter(\.isExpanded)
        let expandedWorktreeCount = expandedBoards.reduce(0) { $0 + $1.worktrees.filter(\.isExpanded).count }
        AppLogger.shared.log("[Nav] refreshExpandedNodes: \(expandedBoards.count) boards, \(expandedWorktreeCount) worktrees — 1 session fetch", level: .debug, category: "Nav")
        // Single session fetch for all worktrees (server doesn't support per-worktree filter)
        let grouped = await fetchAllSessions()
        assignSessions(grouped)
    }

    // MARK: - Socket Handlers

    private func setupSocketHandlers() {
        socketService.onSessionPatched { [weak self] session in
            Task { @MainActor [weak self] in
                self?.handleSessionUpdate(session)
            }
        }
    }

    private func handleSessionUpdate(_ session: Session) {
        for board in boardNodes {
            for wt in board.worktrees {
                if let idx = wt.sessions.firstIndex(where: { $0.sessionId == session.sessionId }) {
                    let oldStatus = wt.sessions[idx].status.rawValue
                    let newStatus = session.status.rawValue
                    let sessionId = String(session.sessionId.prefix(8))
                    if session.archived == true {
                        wt.sessions.remove(at: idx)
                        AppLogger.shared.log("[Nav] onSessionPatched \(sessionId): \(oldStatus) → archived", level: .debug, category: "Nav")
                    } else if wt.sessions[idx] != session {
                        wt.sessions[idx] = session
                        if oldStatus != newStatus {
                            AppLogger.shared.log("[Nav] onSessionPatched \(sessionId): \(oldStatus) → \(newStatus)", level: .debug, category: "Nav")
                        }
                    }
                    wt.sessions = orderedSessionsForDisplay(wt.sessions)
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
            AppLogger.shared.log("[Nav] archiveSession \(String(sessionId.prefix(8))) failed: \(error.localizedDescription)", level: .error, category: "Nav")
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

    /// Look up board/worktree context by worktreeId directly — O(n), always correct.
    func findContext(for session: Session) -> (boardName: String, worktreeName: String, boardIcon: String)? {
        for board in boardNodes {
            for wt in board.worktrees where wt.worktree.worktreeId == session.worktreeId {
                return (board.board.name, wt.worktree.displayName, board.board.displayIcon)
            }
        }
        return nil
    }

    /// Legacy overload for callers that only have sessionId.
    func findContext(for sessionId: String) -> (boardName: String, worktreeName: String, boardIcon: String)? {
        for board in boardNodes {
            for wt in board.worktrees {
                if let session = wt.sessions.first(where: { $0.sessionId == sessionId }) {
                    return findContext(for: session)
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

    // MARK: - Widget Data

    /// Fetch last message for each favorited session and write to App Group UserDefaults.
    /// Called after sidebar refresh and on app foreground.
    func refreshWidgetData() async {
        let favorites = Array(favoriteSessions.prefix(10))
        guard !favorites.isEmpty else {
            WidgetDataWriter.write(sessions: [], serverURL: client.baseURL)
            return
        }

        var widgetSessions: [WidgetSessionData] = []
        await withTaskGroup(of: WidgetSessionData?.self) { group in
            for session in favorites {
                group.addTask {
                    var lastMsg = ""
                    var lastRole = "assistant"
                    if let response: PaginatedResponse<Message> = try? await self.client.getPaginated(
                        "/messages",
                        query: [
                            "session_id": session.sessionId,
                            "$limit": "1",
                            "$sort[created_at]": "-1",
                        ]
                    ), let msg = response.data.first {
                        lastMsg = String(msg.contentPreview.prefix(300))
                        lastRole = msg.role.rawValue
                    }
                    return WidgetSessionData(
                        sessionId: session.sessionId,
                        sessionTitle: session.displayTitle,
                        lastMessage: lastMsg,
                        lastMessageRole: lastRole,
                        lastUpdated: session.lastUpdated.asDate ?? Date(),
                        status: session.status.rawValue
                    )
                }
            }
            for await result in group {
                if let data = result { widgetSessions.append(data) }
            }
        }
        widgetSessions.sort { $0.lastUpdated > $1.lastUpdated }
        WidgetDataWriter.write(sessions: widgetSessions, serverURL: client.baseURL)
    }

    /// Expand the board and worktree that contain this session so it is visible in the sidebar tree.
    func revealSession(_ session: Session) {
        for boardNode in boardNodes {
            guard let wtNode = boardNode.worktrees.first(where: { $0.worktree.worktreeId == session.worktreeId }) else { continue }
            if !boardNode.isExpanded {
                boardNode.isExpanded = true
                setBoardExpanded(boardNode.board.boardId, expanded: true)
                Task { await loadWorktrees(for: boardNode) }
            }
            if !wtNode.isExpanded {
                wtNode.isExpanded = true
                setWorktreeExpanded(wtNode.worktree.worktreeId, expanded: true)
                Task { await loadSessions(for: wtNode) }
            }
            return
        }
    }
}
