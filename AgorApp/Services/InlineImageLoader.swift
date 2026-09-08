import Foundation

/// Serializes chat thumbnail downloads.
///
/// Every `InlineImageView` used to fire its own `serviceGet` from `.task`, so a
/// message list with a dozen images opened a dozen concurrent fetches over the
/// single socket connection. Large base64 payloads then starved each other and
/// the 30s acks timed out — images stayed blank. Fetches now run one at a time,
/// and identical paths share one request.
@Observable
@MainActor
final class InlineImageLoader {
    static let shared = InlineImageLoader()

    enum Phase {
        case scanning
        case downloading
    }

    struct Progress {
        var phase: Phase
        var bytesReceived: Int = 0
        var expectedTotalBytes: Int?
    }

    /// Tail of the serial chain — each new fetch awaits the previous one.
    private var lastTask: Task<Void, Never>?
    /// In-flight fetches keyed by server + worktree + path.
    private var inFlight: [String: Task<FileDetail, Error>] = [:]
    /// Per-key progress, observed by views showing a placeholder for that key.
    private(set) var progress: [String: Progress] = [:]

    /// Backoff between retries of a failed download. Read-only GETs only —
    /// never retries anything that could resend a chat message or attachment.
    private static let retryDelays: [Duration] = [.seconds(1), .seconds(3)]

    static func progressKey(baseURL: String, worktreeId: String, path: String) -> String {
        "\(baseURL)|\(worktreeId)|\(path)"
    }

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

        let key = Self.progressKey(baseURL: baseURL, worktreeId: worktreeId, path: path)
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

            guard let self else { throw CancellationError() }
            do {
                let detail = try await self.fetchWithFallback(
                    path: path, worktreeId: worktreeId, socketService: socketService, baseURL: baseURL, key: key
                )
                FileContentCache.store(detail, baseURL: baseURL, worktreeId: worktreeId, path: path)
                self.inFlight[key] = nil
                self.progress[key] = nil
                return detail
            } catch {
                self.progress[key] = nil
                throw error
            }
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

    /// Attempt the path exactly as the assistant wrote it (with bounded
    /// retries) before paying for a full worktree file-list scan — the scan is
    /// only worth its cost when the literal path genuinely doesn't resolve.
    private func fetchWithFallback(
        path: String,
        worktreeId: String,
        socketService: SocketService,
        baseURL: String,
        key: String
    ) async throws -> FileDetail {
        do {
            return try await fetchWithRetries(path: path, worktreeId: worktreeId, socketService: socketService, key: key)
        } catch {
            AppLogger.shared.log(
                "[InlineImage] direct fetch failed for \"\(path)\" after retries — scanning file list to resolve the path",
                level: .warning, category: "FileBrowser"
            )
            progress[key] = Progress(phase: .scanning)
            let files: [FileListItem]
            do {
                files = try await socketService.serviceFind(service: "file", query: ["branch_id": worktreeId])
            } catch {
                throw error
            }
            let resolved = FilePathDetector.resolve(path, knownFiles: files.map(\.path))
            guard resolved != path else { throw error }
            AppLogger.shared.log("[InlineImage] resolved \"\(path)\" → \"\(resolved)\"", level: .info, category: "FileBrowser")
            progress[key] = Progress(phase: .downloading)
            return try await fetchWithRetries(path: resolved, worktreeId: worktreeId, socketService: socketService, key: key)
        }
    }

    /// One path, retried with bounded backoff. Every attempt is a read-only
    /// GET — this must never be reused for anything that sends data, or a
    /// retry could duplicate a chat message/attachment.
    private func fetchWithRetries(
        path: String,
        worktreeId: String,
        socketService: SocketService,
        key: String
    ) async throws -> FileDetail {
        var lastError: Error!
        for attempt in 0...Self.retryDelays.count {
            do {
                return try await fetchOnce(path: path, worktreeId: worktreeId, socketService: socketService, key: key)
            } catch {
                lastError = error
                // Logged so a reported "content changed on retry" can be traced
                // to a specific attempt/path/error after the fact.
                AppLogger.shared.log(
                    "[InlineImage] fetch attempt \(attempt + 1) failed for \"\(path)\": \(error.localizedDescription)",
                    level: .warning, category: "FileBrowser"
                )
                if attempt < Self.retryDelays.count {
                    try? await Task.sleep(for: Self.retryDelays[attempt])
                }
            }
        }
        throw lastError
    }

    /// Single HTTP attempt (streaming, size-aware timeout), falling back to
    /// the socket transport on failure.
    private func fetchOnce(
        path: String,
        worktreeId: String,
        socketService: SocketService,
        key: String
    ) async throws -> FileDetail {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encodedId = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path

        progress[key] = Progress(phase: .downloading)
        do {
            let detail: FileDetail = try await socketService.httpClient.getStreaming(
                "/file/\(encodedId)",
                query: ["worktree_id": worktreeId, "branch_id": worktreeId]
            ) { [weak self] update in
                Task { @MainActor in
                    self?.progress[key] = Progress(
                        phase: .downloading,
                        bytesReceived: update.bytesReceived,
                        expectedTotalBytes: update.expectedTotalBytes
                    )
                }
            }
            return detail
        } catch {
            AppLogger.shared.log(
                "[InlineImage] HTTP fetch failed for \"\(path)\" (\(error.localizedDescription)) — falling back to socket",
                level: .warning, category: "FileBrowser"
            )
            return try await socketService.serviceGet(
                service: "file",
                id: path,
                query: ["branch_id": worktreeId]
            )
        }
    }
}
