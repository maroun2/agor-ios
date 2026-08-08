import CryptoKit
import Foundation

/// On-disk cache for binary file payloads fetched from the daemon — images shown
/// as chat thumbnails, PDFs and other files opened in the in-app viewer, and
/// downloads. Entries expire after 3 days and are pruned at launch.
///
/// Only base64 (binary) payloads are cached. Text files are deliberately NOT
/// cached: they are source files in a live worktree and change constantly, so a
/// stale copy would silently show the wrong code in the file browser.
enum FileContentCache {
    /// How long an entry stays valid. Files can change on the server, so this is
    /// a freshness ceiling, not just a storage bound.
    static let maxAge: TimeInterval = 3 * 24 * 60 * 60  // 3 days

    private static let directoryName = "file-content-cache"

    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Cache key covers server + worktree + path, so the same file under two
    /// servers or worktrees never collides. Both the HTTP and socket fetch paths
    /// derive the same key, so a chat thumbnail and the file browser share one entry.
    private static func key(baseURL: String, worktreeId: String, path: String) -> String {
        let digest = SHA256.hash(data: Data("\(baseURL)|\(worktreeId)|\(path)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func entryURL(baseURL: String, worktreeId: String, path: String) -> URL {
        directory.appendingPathComponent("\(key(baseURL: baseURL, worktreeId: worktreeId, path: path)).json")
    }

    // MARK: - Read / Write

    /// Cached payload for this file, or nil on a miss. Entries older than
    /// `maxAge` are deleted and reported as a miss.
    static func load(baseURL: String, worktreeId: String, path: String) -> FileDetail? {
        let url = entryURL(baseURL: baseURL, worktreeId: worktreeId, path: path)
        guard let data = try? Data(contentsOf: url) else { return nil }

        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, Date().timeIntervalSince(modified) > maxAge {
            try? FileManager.default.removeItem(at: url)
            AppLogger.shared.log("[FileCache] expired \(path)", level: .debug, category: "FileBrowser")
            return nil
        }

        guard let detail = try? JSONDecoder.agor.decode(FileDetail.self, from: data) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        AppLogger.shared.log("[FileCache] hit \(path)", level: .debug, category: "FileBrowser")
        return detail
    }

    /// Store a freshly fetched payload. Text files are ignored — see the type comment.
    static func store(_ detail: FileDetail, baseURL: String, worktreeId: String, path: String) {
        guard detail.encoding == "base64", detail.content != nil else { return }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder.agor.encode(detail)
            try data.write(to: entryURL(baseURL: baseURL, worktreeId: worktreeId, path: path), options: .atomic)
            AppLogger.shared.log("[FileCache] stored \(path) (\(data.count) bytes)", level: .debug, category: "FileBrowser")
        } catch {
            // Non-fatal — a cache write failure just means the next open refetches
        }
    }

    // MARK: - Maintenance

    /// Delete entries older than `maxAge`. Called at launch.
    static func prune() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let now = Date()
        var removed = 0
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > maxAge else { continue }
            try? fm.removeItem(at: entry)
            removed += 1
        }
        if removed > 0 {
            AppLogger.shared.log("[FileCache] pruned \(removed) expired entries", level: .info, category: "FileBrowser")
        }
    }

    /// Drop everything — used when the cache should be rebuilt from scratch.
    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
