import Foundation

@Observable
@MainActor
final class FileBrowserViewModel {
    var files: [FileListItem] = []
    var currentPath: String = ""
    var isLoading = false
    private var hasLoadedOnce = false
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

    func loadFiles() async {
        guard !isLoading else { return }
        hasLoadedOnce = true
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
        if let cached = FileContentCache.load(baseURL: baseURL, worktreeId: worktreeId, path: filePath) {
            return cached
        }

        // Encode the path as ONE Feathers id segment: "/" must become %2F so the
        // route matches; Express decodes the param back to the full path.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encodedId = filePath.addingPercentEncoding(withAllowedCharacters: allowed) ?? filePath

        do {
            // Send both param spellings — older daemons use worktree_id, newer branch_id
            let detail: FileDetail = try await socketService.httpClient.get(
                "/file/\(encodedId)",
                query: ["worktree_id": worktreeId, "branch_id": worktreeId]
            )
            FileContentCache.store(detail, baseURL: baseURL, worktreeId: worktreeId, path: filePath)
            return detail
        } catch {
            AppLogger.shared.log(
                "[FileBrowser] HTTP file fetch failed (\(error.localizedDescription)) — falling back to socket",
                level: .warning, category: "FileBrowser"
            )
            let detail: FileDetail = try await socketService.serviceGet(
                service: "file",
                id: filePath,
                query: ["branch_id": worktreeId]
            )
            FileContentCache.store(detail, baseURL: baseURL, worktreeId: worktreeId, path: filePath)
            return detail
        }
    }

    /// Drop this file's cached copy and pull it fresh from the server.
    func redownloadFile(_ filePath: String) async {
        FileContentCache.remove(baseURL: socketService.httpClient.baseURL, worktreeId: worktreeId, path: filePath)
        AppLogger.shared.log("[FileBrowser] cache cleared, redownloading \"\(filePath)\"", level: .info, category: "FileBrowser")
        await loadFileDetail(filePath)
    }

    func loadFileDetail(_ filePath: String) async {
        AppLogger.shared.log("[FileBrowser] loadFileDetail path=\"\(filePath)\" worktreeId=\(worktreeId)", level: .debug, category: "FileBrowser")
        isLoadingFile = true
        fileDetail = nil
        do {
            // HTTP REST first (streams large/binary payloads), socket fallback inside
            fileDetail = try await fetchDetail(filePath)
            let byteCount = fileDetail?.content?.utf8.count ?? 0
            AppLogger.shared.log("[FileBrowser] loadFileDetail OK: \(byteCount) bytes", level: .debug, category: "FileBrowser")
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
