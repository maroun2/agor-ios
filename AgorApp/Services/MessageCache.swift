import CryptoKit
import Foundation

/// On-disk cache for the messages of a *finished* task.
///
/// A task in a terminal state (completed / failed / timed out / stopped) will
/// never produce another message, so its transcript is immutable and safe to
/// serve from disk — reopening an old session renders instantly with no network
/// round trip. Tasks still running are never cached: their messages are still
/// arriving over the socket.
enum MessageCache {
    /// Finished transcripts are immutable, so this is a disk-usage bound rather
    /// than a freshness one — long enough that revisiting old sessions still hits.
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60  // 30 days

    private static let directoryName = "message-cache"

    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func entryURL(baseURL: String, taskId: String) -> URL {
        let digest = SHA256.hash(data: Data("\(baseURL)|\(taskId)".utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(key).json")
    }

    // MARK: - Read / Write

    /// Cached transcript for a finished task, or nil on a miss.
    static func load(baseURL: String, taskId: String) -> [Message]? {
        let url = entryURL(baseURL: baseURL, taskId: taskId)
        guard let data = try? Data(contentsOf: url) else { return nil }

        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let modified, Date().timeIntervalSince(modified) > maxAge {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        guard let messages = try? JSONDecoder.agor.decode([Message].self, from: data) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        AppLogger.shared.log("[MessageCache] hit task \(taskId.prefix(8)) (\(messages.count) msgs)", level: .debug, category: "Chat")
        return messages
    }

    /// Store a finished task's transcript. Callers must only pass terminal tasks.
    static func store(_ messages: [Message], baseURL: String, taskId: String) {
        guard !messages.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder.agor.encode(messages)
            try data.write(to: entryURL(baseURL: baseURL, taskId: taskId), options: .atomic)
            AppLogger.shared.log("[MessageCache] stored task \(taskId.prefix(8)) (\(messages.count) msgs)", level: .debug, category: "Chat")
        } catch {
            // Non-fatal — the next open just refetches
        }
    }

    static func remove(baseURL: String, taskId: String) {
        try? FileManager.default.removeItem(at: entryURL(baseURL: baseURL, taskId: taskId))
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
            AppLogger.shared.log("[MessageCache] pruned \(removed) expired entries", level: .info, category: "Chat")
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}
