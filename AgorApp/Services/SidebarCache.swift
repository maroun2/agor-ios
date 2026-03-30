import Foundation

// MARK: - Cached Sidebar Data

struct CachedSidebar: Codable {
    let boards: [CachedBoard]
    let timestamp: Date
}

struct CachedBoard: Codable {
    let board: Board
    let worktrees: [CachedWorktree]
}

struct CachedWorktree: Codable {
    let worktree: Worktree
    let sessions: [Session]
    let repoName: String?
}

// MARK: - Sidebar Cache

enum SidebarCache {
    private static let cacheFileName = "sidebar-cache.json"
    private static let maxAgeSeconds: TimeInterval = 3600 // 1 hour

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(cacheFileName)
    }

    static func save(boardNodes: [BoardNode]) {
        let cached = CachedSidebar(
            boards: boardNodes.map { node in
                CachedBoard(
                    board: node.board,
                    worktrees: node.worktrees.map { wt in
                        CachedWorktree(
                            worktree: wt.worktree,
                            sessions: wt.sessions,
                            repoName: wt.repoName
                        )
                    }
                )
            },
            timestamp: Date()
        )

        do {
            let data = try JSONEncoder.agor.encode(cached)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // Non-fatal — cache write failure is silent
        }
    }

    static func load() -> [BoardNode]? {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder.agor.decode(CachedSidebar.self, from: data) else {
            return nil
        }

        // TTL check
        guard Date().timeIntervalSince(cached.timestamp) < maxAgeSeconds else {
            try? FileManager.default.removeItem(at: cacheURL)
            return nil
        }

        return cached.boards.map { cachedBoard in
            let node = BoardNode(board: cachedBoard.board)
            node.worktrees = cachedBoard.worktrees.map { cachedWT in
                let wtNode = WorktreeNode(worktree: cachedWT.worktree)
                wtNode.sessions = cachedWT.sessions
                wtNode.repoName = cachedWT.repoName
                return wtNode
            }
            return node
        }
    }
}
