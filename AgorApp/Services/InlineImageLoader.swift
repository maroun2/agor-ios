import Foundation

/// Serializes chat thumbnail downloads.
///
/// Every `InlineImageView` used to fire its own `serviceGet` from `.task`, so a
/// message list with a dozen images opened a dozen concurrent fetches over the
/// single socket connection. Large base64 payloads then starved each other and
/// the 30s acks timed out — images stayed blank. Fetches now run one at a time,
/// and identical paths share one request.
@MainActor
final class InlineImageLoader {
    static let shared = InlineImageLoader()

    /// Tail of the serial chain — each new fetch awaits the previous one.
    private var lastTask: Task<Void, Never>?
    /// In-flight fetches keyed by server + worktree + path.
    private var inFlight: [String: Task<FileDetail, Error>] = [:]

    /// Returns the file payload, from the disk cache when possible, otherwise
    /// queued behind every other pending thumbnail fetch.
    func load(
        path: String,
        worktreeId: String,
        socketService: SocketService
    ) async throws -> FileDetail {
        let baseURL = socketService.httpClient.baseURL
        // Cache hits must not wait behind the queue.
        if let cached = FileContentCache.load(baseURL: baseURL, worktreeId: worktreeId, path: path) {
            return cached
        }

        let key = "\(baseURL)|\(worktreeId)|\(path)"
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let previous = lastTask
        let fetch = Task<FileDetail, Error> { [weak self] in
            // Actor reentrancy means an `await` alone does not serialize; the
            // chain does. Waiting on the previous link is what keeps exactly one
            // request on the wire.
            _ = await previous?.value

            // The queue may have moved while waiting — an earlier entry could
            // have fetched this same path.
            if let cached = FileContentCache.load(baseURL: baseURL, worktreeId: worktreeId, path: path) {
                return cached
            }

            // HTTP, not the socket: the express route is gzipped (base64
            // compresses well) and it doesn't share a connection with every
            // other socket message. The socket remains the fallback.
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "/")
            let encodedId = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path

            let detail: FileDetail
            do {
                detail = try await socketService.httpClient.get(
                    "/file/\(encodedId)",
                    query: ["worktree_id": worktreeId, "branch_id": worktreeId]
                )
            } catch {
                AppLogger.shared.log(
                    "[InlineImage] HTTP fetch failed for \"\(path)\" (\(error.localizedDescription)) — falling back to socket",
                    level: .warning, category: "FileBrowser"
                )
                detail = try await socketService.serviceGet(
                    service: "file",
                    id: path,
                    query: ["branch_id": worktreeId]
                )
            }
            FileContentCache.store(detail, baseURL: baseURL, worktreeId: worktreeId, path: path)
            self?.inFlight[key] = nil
            return detail
        }
        inFlight[key] = fetch

        // Deliberately not cancelled with the caller: a view scrolled off screen
        // should still finish its download into the cache so scrolling back is a
        // hit rather than another trip through the queue.
        lastTask = Task { _ = try? await fetch.value }

        do {
            return try await fetch.value
        } catch {
            inFlight[key] = nil
            throw error
        }
    }
}
