import Foundation

@Observable
@MainActor
final class FileBrowserViewModel {
    var files: [FileListItem] = []
    var currentPath: String = ""
    var isLoading = false
    private var hasLoadedOnce = false
    /// Shortest gap between two message-driven file list scans.
    private static let minListRefreshInterval: TimeInterval = 15
    @ObservationIgnored private var lastListLoad: Date?
    @ObservationIgnored private var pendingListRefresh: Task<Void, Never>?
    var error: String?
    /// True when the server reports the worktree no longer exists (stale ID)
    var isWorktreeGone = false
    var fileDetail: FileDetail?
    var isLoadingFile = false
    /// Set by chat links to auto-navigate to a specific file when the browser opens
    var pendingFilePath: String?

    /// Cached file paths for link resolution in chat messages
    var filePaths: [String] { files.map(\.path) }

    let worktreeId: String
    private let socketService: SocketService

    init(worktreeId: String, socketService: SocketService) {
        self.worktreeId = worktreeId
        self.socketService = socketService
    }

    // Directories at current path
    var currentDirectories: [String] {
        let prefix = currentPath.isEmpty ? "" : currentPath + "/"
        var dirs = Set<String>()
        for file in files {
            guard file.path.hasPrefix(prefix) else { continue }
            let remainder = String(file.path.dropFirst(prefix.count))
            let components = remainder.components(separatedBy: "/")
            if components.count > 1 {
                dirs.insert(components[0])
            }
        }
        return dirs.sorted()
    }

    // Files at current path (not in subdirectories)
    var currentFiles: [FileListItem] {
        let prefix = currentPath.isEmpty ? "" : currentPath + "/"
        return files.filter { file in
            guard file.path.hasPrefix(prefix) else { return false }
            let remainder = String(file.path.dropFirst(prefix.count))
            return !remainder.contains("/")
        }.sorted { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
    }

    var pathComponents: [String] {
        currentPath.isEmpty ? [] : currentPath.components(separatedBy: "/")
    }

    /// Fetch the worktree file list. The daemon re-walks the entire tree on every
    /// call, so this is expensive on both ends — an already-loaded list is reused
    /// unless the caller explicitly asks for a fresh scan.
    /// A new message can mention files that didn't exist at the last scan, and
    /// paths only turn into links when they resolve against a known file. One
    /// refresh per burst of arriving messages, rate-limited — the daemon walks
    /// the whole worktree for every scan, so this must not run per message.
    func refreshFileListForNewMessages() {
        pendingListRefresh?.cancel()
        pendingListRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            if let last = lastListLoad, Date().timeIntervalSince(last) < Self.minListRefreshInterval {
                return
            }
            await loadFiles(force: true)
        }
    }

    func loadFiles(force: Bool = false) async {
        guard !isLoading else { return }
        if !force, hasLoadedOnce, !files.isEmpty {
            AppLogger.shared.log("[FileBrowser] loadFiles skipped — \(files.count) files already loaded", level: .debug, category: "FileBrowser")
            return
        }
        hasLoadedOnce = true
        lastListLoad = Date()
        let listStart = CFAbsoluteTimeGetCurrent()
        defer {
            AppLogger.shared.log("[Timing] file list find \(Self.ms(since: listStart))ms (\(files.count) entries)", level: .info, category: "FileBrowser")
        }
        let displayPath = currentPath.isEmpty ? "/" : currentPath
        AppLogger.shared.log("[FileBrowser] loadFiles worktreeId=\(worktreeId) path=\"\(displayPath)\"", level: .debug, category: "FileBrowser")
        isLoading = true
        error = nil
        isWorktreeGone = false
        do {
            // Use Socket.IO like the web UI — auth is resolved at socket connection level
            files = try await socketService.serviceFind(
                service: "file",
                query: ["branch_id": worktreeId]
            )
            let dirCount = currentDirectories.count
            let fileCount = currentFiles.count
            AppLogger.shared.log("[FileBrowser] loadFiles OK: \(dirCount) dirs, \(fileCount) files", level: .debug, category: "FileBrowser")
        } catch {
            AppLogger.shared.log("[FileBrowser] loadFiles ERROR: \(error.localizedDescription)", level: .error, category: "FileBrowser")
            if Self.isWorktreeNotFound(error) {
                isWorktreeGone = true
                self.error = "This worktree no longer exists on the server."
                SidebarCache.clear()
            } else {
                self.error = "Failed to load files: \(error.localizedDescription)"
            }
        }
        isLoading = false
    }

    func navigateTo(_ directory: String) {
        if currentPath.isEmpty {
            currentPath = directory
        } else {
            currentPath = currentPath + "/" + directory
        }
        AppLogger.shared.log("[FileBrowser] navigate to \"\(currentPath)\"", level: .debug, category: "FileBrowser")
    }

    func navigateUp() {
        let components = currentPath.components(separatedBy: "/")
        if components.count > 1 {
            currentPath = components.dropLast().joined(separator: "/")
        } else {
            currentPath = ""
        }
        let displayPath = currentPath.isEmpty ? "root" : currentPath
        AppLogger.shared.log("[FileBrowser] navigate up to \"\(displayPath)\"", level: .debug, category: "FileBrowser")
    }

    func navigateToRoot() {
        currentPath = ""
        AppLogger.shared.log("[FileBrowser] navigate to root", level: .debug, category: "FileBrowser")
    }

    func fetchFileData(_ filePath: String) async throws -> (Data, String) {
        let detail = try await fetchDetail(filePath)
        guard let content = detail.content else {
            throw NSError(domain: "FileBrowser", code: 0, userInfo: [NSLocalizedDescriptionKey: "No content"])
        }
        let fileName = filePath.components(separatedBy: "/").last ?? filePath
        if detail.encoding == "base64", let data = Data(base64Encoded: content) {
            return (data, fileName)
        } else {
            return (Data(content.utf8), fileName)
        }
    }

    /// Fetch a file over authenticated HTTP REST (the Feathers file service is
    /// also mounted on the REST transport). Socket.IO buffers the whole response
    /// in one JSON packet, which is fragile for large/binary files — URLSession
    /// streams the HTTP body instead. Falls back to the socket on HTTP failure.
    private func fetchDetail(_ filePath: String) async throws -> FileDetail {
        let baseURL = socketService.httpClient.baseURL

        // Binary payloads (images, PDFs, downloads) are cached on disk for 3 days.
        // Text is never cached — worktree source changes constantly.
        let cacheStart = CFAbsoluteTimeGetCurrent()
        if let cached = FileContentCache.load(baseURL: baseURL, worktreeId: worktreeId, path: filePath) {
            AppLogger.shared.log(
                "[Timing] cache hit \"\(filePath)\" in \(Self.ms(since: cacheStart))ms",
                level: .info, category: "FileBrowser"
            )
            return cached
        }
        AppLogger.shared.log(
            "[Timing] cache miss \"\(filePath)\" (lookup \(Self.ms(since: cacheStart))ms)",
            level: .info, category: "FileBrowser"
        )

        // Encode the path as ONE Feathers id segment: "/" must become %2F so the
        // route matches; Express decodes the param back to the full path.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encodedId = filePath.addingPercentEncoding(withAllowedCharacters: allowed) ?? filePath

        do {
            // Send both param spellings — older daemons use worktree_id, newer branch_id
            let httpStart = CFAbsoluteTimeGetCurrent()
            let detail: FileDetail = try await socketService.httpClient.get(
                "/file/\(encodedId)",
                query: ["worktree_id": worktreeId, "branch_id": worktreeId]
            )
            AppLogger.shared.log(
                "[Timing] HTTP fetch+decode \(Self.ms(since: httpStart))ms (\(detail.content?.utf8.count ?? 0) content bytes)",
                level: .info, category: "FileBrowser"
            )
            let storeStart = CFAbsoluteTimeGetCurrent()
            FileContentCache.store(detail, baseURL: baseURL, worktreeId: worktreeId, path: filePath)
            AppLogger.shared.log("[Timing] cache store \(Self.ms(since: storeStart))ms", level: .info, category: "FileBrowser")
            return detail
        } catch {
            AppLogger.shared.log(
                "[FileBrowser] HTTP file fetch failed (\(error.localizedDescription)) — falling back to socket",
                level: .warning, category: "FileBrowser"
            )
            let socketStart = CFAbsoluteTimeGetCurrent()
            let detail: FileDetail = try await socketService.serviceGet(
                service: "file",
                id: filePath,
                query: ["branch_id": worktreeId]
            )
            AppLogger.shared.log(
                "[Timing] SOCKET fallback fetch+decode \(Self.ms(since: socketStart))ms (\(detail.content?.utf8.count ?? 0) content bytes)",
                level: .info, category: "FileBrowser"
            )
            let storeStart = CFAbsoluteTimeGetCurrent()
            FileContentCache.store(detail, baseURL: baseURL, worktreeId: worktreeId, path: filePath)
            AppLogger.shared.log("[Timing] cache store \(Self.ms(since: storeStart))ms", level: .info, category: "FileBrowser")
            return detail
        }
    }

    /// Match a path written in a message against the real worktree tree. Only
    /// used after a direct fetch has already failed — an exact path never needs
    /// the file list at all.
    private func resolvePathAgainstFileList(_ filePath: String) -> String? {
        guard !files.isEmpty else { return nil }
        let paths = files.map(\.path)
        if paths.contains(filePath) { return filePath }

        let suffixMatches = paths.filter { $0.hasSuffix("/" + filePath) }
        if suffixMatches.count == 1 { return suffixMatches[0] }

        let name = filePath.components(separatedBy: "/").last ?? filePath
        let nameMatches = paths.filter { ($0.components(separatedBy: "/").last ?? $0) == name }
        return nameMatches.count == 1 ? nameMatches[0] : nil
    }

    /// Elapsed milliseconds since a CFAbsoluteTime mark, for the [Timing] lines
    /// that break a file open into its steps.
    static func ms(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    /// Drop this file's cached copy and pull it fresh from the server.
    func redownloadFile(_ filePath: String) async {
        FileContentCache.remove(baseURL: socketService.httpClient.baseURL, worktreeId: worktreeId, path: filePath)
        AppLogger.shared.log("[FileBrowser] cache cleared, redownloading \"\(filePath)\"", level: .info, category: "FileBrowser")
        await loadFileDetail(filePath)
    }

    func loadFileDetail(_ filePath: String) async {
        AppLogger.shared.log("[FileBrowser] loadFileDetail path=\"\(filePath)\" worktreeId=\(worktreeId)", level: .debug, category: "FileBrowser")
        let openStart = CFAbsoluteTimeGetCurrent()
        isLoadingFile = true
        fileDetail = nil
        do {
            // HTTP REST first (streams large/binary payloads), socket fallback inside
            var detail: FileDetail
            do {
                detail = try await fetchDetail(filePath)
            } catch {
                // Only now is the file list worth its cost: the path as written
                // in the message didn't resolve on the server, so scan the tree
                // and try to match it against a real one.
                AppLogger.shared.log(
                    "[FileBrowser] direct fetch failed for \"\(filePath)\" — scanning file list to resolve the path",
                    level: .warning, category: "FileBrowser"
                )
                await loadFiles()
                guard let resolved = resolvePathAgainstFileList(filePath), resolved != filePath else { throw error }
                AppLogger.shared.log("[FileBrowser] resolved \"\(filePath)\" → \"\(resolved)\"", level: .info, category: "FileBrowser")
                detail = try await fetchDetail(resolved)
            }
            fileDetail = detail
            let byteCount = fileDetail?.content?.utf8.count ?? 0
            AppLogger.shared.log("[FileBrowser] loadFileDetail OK: \(byteCount) bytes", level: .debug, category: "FileBrowser")
            AppLogger.shared.log(
                "[Timing] TOTAL tap→content \(Self.ms(since: openStart))ms for \"\(filePath)\" (\(byteCount) bytes)",
                level: .info, category: "FileBrowser"
            )
        } catch {
            AppLogger.shared.log("[FileBrowser] loadFileDetail ERROR: \(error.localizedDescription)", level: .error, category: "FileBrowser")
            if Self.isWorktreeNotFound(error) {
                isWorktreeGone = true
                self.error = "This worktree no longer exists on the server."
                SidebarCache.clear()
            } else {
                self.error = "Failed to load file: \(error.localizedDescription)"
            }
        }
        isLoadingFile = false
    }

    // MARK: - Stale Worktree Detection

    private static func isWorktreeNotFound(_ error: Error) -> Bool {
        if case AgorAPIError.httpError(let code, let body) = error {
            let msg = (body ?? "").lowercased()
            if msg.contains("worktree") && msg.contains("not found") { return true }
            if code == 404 { return true }
        }
        return false
    }
}
