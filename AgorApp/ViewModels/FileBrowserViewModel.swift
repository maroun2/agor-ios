import Foundation

@Observable
final class FileBrowserViewModel {
    var files: [FileListItem] = []
    var currentPath: String = ""
    var isLoading = false
    private var hasLoadedOnce = false
    var error: String?
    var fileDetail: FileDetail?
    var isLoadingFile = false

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
        do {
            // Use Socket.IO like the web UI — auth is resolved at socket connection level
            files = try await socketService.serviceFind(
                service: "file",
                query: ["worktree_id": worktreeId]
            )
            let dirCount = currentDirectories.count
            let fileCount = currentFiles.count
            AppLogger.shared.log("[FileBrowser] loadFiles OK: \(dirCount) dirs, \(fileCount) files", level: .debug, category: "FileBrowser")
        } catch {
            AppLogger.shared.log("[FileBrowser] loadFiles ERROR: \(error.localizedDescription)", level: .error, category: "FileBrowser")
            self.error = "Failed to load files: \(error.localizedDescription)"
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

    func loadFileDetail(_ filePath: String) async {
        AppLogger.shared.log("[FileBrowser] loadFileDetail path=\"\(filePath)\" worktreeId=\(worktreeId)", level: .debug, category: "FileBrowser")
        isLoadingFile = true
        fileDetail = nil
        do {
            // Use Socket.IO like the web UI
            fileDetail = try await socketService.serviceGet(
                service: "file",
                id: filePath,
                query: ["worktree_id": worktreeId]
            )
            let byteCount = fileDetail?.content?.utf8.count ?? 0
            AppLogger.shared.log("[FileBrowser] loadFileDetail OK: \(byteCount) bytes", level: .debug, category: "FileBrowser")
        } catch {
            AppLogger.shared.log("[FileBrowser] loadFileDetail ERROR: \(error.localizedDescription)", level: .error, category: "FileBrowser")
            self.error = "Failed to load file: \(error.localizedDescription)"
        }
        isLoadingFile = false
    }
}
