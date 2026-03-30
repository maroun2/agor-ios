import Foundation

@Observable
final class FileBrowserViewModel {
    var files: [FileListItem] = []
    var currentPath: String = ""
    var isLoading = false
    var error: String?
    var fileDetail: FileDetail?
    var isLoadingFile = false

    let worktreeId: String
    private let client: AgorClient

    init(worktreeId: String, client: AgorClient) {
        self.worktreeId = worktreeId
        self.client = client
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
        isLoading = true
        error = nil
        do {
            files = try await client.get("/file", query: ["worktree_id": worktreeId])
        } catch {
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
    }

    func navigateUp() {
        let components = currentPath.components(separatedBy: "/")
        if components.count > 1 {
            currentPath = components.dropLast().joined(separator: "/")
        } else {
            currentPath = ""
        }
    }

    func navigateToRoot() {
        currentPath = ""
    }

    func loadFileDetail(_ filePath: String) async {
        isLoadingFile = true
        fileDetail = nil
        do {
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove("/")
            let encodedPath = filePath.addingPercentEncoding(withAllowedCharacters: allowed) ?? filePath
            fileDetail = try await client.get("/file/\(encodedPath)", query: ["worktree_id": worktreeId])
        } catch {
            self.error = "Failed to load file: \(error.localizedDescription)"
        }
        isLoadingFile = false
    }
}
