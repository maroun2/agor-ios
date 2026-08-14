import Foundation

// MARK: - API Error

enum AgorAPIError: Error, LocalizedError {
    case invalidURL
    case notAuthenticated
    case httpError(statusCode: Int, body: String?)
    case decodingError(Error)
    case networkError(Error)
    case tokenRefreshFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid URL"
        case .notAuthenticated: "Not authenticated"
        case .httpError(let code, let body): "HTTP \(code): \(body ?? "Unknown error")"
        // The underlying error names the offending key and type; the localized
        // description flattens all of that into "the data couldn't be read".
        case .decodingError(let err): "Decoding error: \(err)"
        case .networkError(let err): "Network error: \(err.localizedDescription)"
        case .tokenRefreshFailed: "Session expired. Please log in again."
        }
    }
}

// MARK: - Agor REST Client

@Observable
final class AgorClient {
    var baseURL: String = ""
    var accessToken: String?
    var refreshToken: String?
    var isRefreshing = false

    /// Called on main thread when token refresh fails permanently.
    /// Wire this to logout in the app entry point.
    var onSessionExpired: (() -> Void)?

    /// Called after the access token is successfully replaced. The socket
    /// authenticated with the *previous* token and the server keeps that
    /// connection bound to it, so it has to re-authenticate or it silently stops
    /// receiving events while HTTP keeps working.
    var onTokenRefreshed: (() -> Void)?

    /// Called when JWT refresh fails (or no refresh token) before giving up.
    /// Should attempt password-based re-login with stored credentials.
    /// Throw on failure so AgorClient knows to proceed to onSessionExpired.
    var onSilentReAuth: (() async throws -> Void)?

    private let session: URLSession
    private let decoder = JSONDecoder.agor
    private let encoder = JSONEncoder.agor
    private let refreshLock = NSLock()
    private var inFlightRefresh: Task<Bool, Never>?

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
    }

    // MARK: - Generic HTTP Methods

    func get<T: Codable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let request = try buildRequest(path: path, method: "GET", query: query)
        logOutgoingRequest(request)
        return try await execute(request)
    }

    func getPaginated<T: Codable>(_ path: String, query: [String: String] = [:]) async throws -> PaginatedResponse<T> {
        let request = try buildRequest(path: path, method: "GET", query: query)
        logOutgoingRequest(request)
        return try await execute(request)
    }

    func post<T: Codable>(_ path: String, body: some Encodable) async throws -> T {
        var request = try buildRequest(path: path, method: "POST")
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        logOutgoingRequest(request)
        return try await execute(request)
    }

    func postRaw(_ path: String, body: some Encodable) async throws -> Data {
        var request = try buildRequest(path: path, method: "POST")
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        logOutgoingRequest(request)
        return try await executeRaw(request, attemptRefresh: true)
    }

    func patch<T: Codable>(_ path: String, body: some Encodable) async throws -> T {
        var request = try buildRequest(path: path, method: "PATCH")
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        logOutgoingRequest(request)
        return try await execute(request)
    }

    func delete(_ path: String) async throws -> Data {
        let request = try buildRequest(path: path, method: "DELETE")
        logOutgoingRequest(request)
        return try await executeRaw(request, attemptRefresh: true)
    }

    // MARK: - Request Building

    private func buildRequest(path: String, method: String, query: [String: String] = [:]) throws -> URLRequest {
        guard !baseURL.isEmpty else { throw AgorAPIError.invalidURL }

        var components = URLComponents(string: "\(baseURL)\(path)")
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else { throw AgorAPIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = method

        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    // MARK: - Request Logging

    private func logOutgoingRequest(_ request: URLRequest) {
        let method = request.httpMethod ?? "?"
        let fullURL = request.url?.absoluteString ?? "?"
        // Strip the baseURL prefix to show just path + query
        let pathAndQuery: String
        if !baseURL.isEmpty, fullURL.hasPrefix(baseURL) {
            pathAndQuery = String(fullURL.dropFirst(baseURL.count))
        } else {
            pathAndQuery = fullURL
        }

        if let body = request.httpBody, let bodyString = String(data: body, encoding: .utf8) {
            let redacted = bodyString.replacingOccurrences(
                of: #""password"\s*:\s*"[^"]*""#,
                with: "\"password\":\"***\"",
                options: .regularExpression)
            let truncated = redacted.count > 500 ? String(redacted.prefix(500)) + "..." : redacted
            AppLogger.shared.log("[HTTP] → \(method) \(pathAndQuery) body=\(truncated)", level: .debug, category: "HTTP")
        } else {
            AppLogger.shared.log("[HTTP] → \(method) \(pathAndQuery)", level: .debug, category: "HTTP")
        }
    }

    private func requestLabel(for request: URLRequest) -> String {
        let method = request.httpMethod ?? "?"
        let fullURL = request.url?.absoluteString ?? "?"
        if !baseURL.isEmpty, fullURL.hasPrefix(baseURL) {
            return "\(method) \(String(fullURL.dropFirst(baseURL.count)))"
        }
        return "\(method) \(fullURL)"
    }

    // MARK: - Execution with Auto-Refresh

    private func execute<T: Codable>(_ request: URLRequest) async throws -> T {
        let data = try await executeRaw(request, attemptRefresh: true)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw AgorAPIError.decodingError(error)
        }
    }

    private func executeRaw(_ request: URLRequest, attemptRefresh: Bool) async throws -> Data {
        let label = requestLabel(for: request)
        let start = Date()

        var request = request
        // Renew before the token dies rather than after: waiting for the 401
        // costs a wasted round trip, and any request in flight at the moment of
        // expiry fails on transports that can't retry (uploads, the socket).
        // `attemptRefresh == false` marks the refresh call itself and its retry.
        if attemptRefresh, let token = accessToken, let exp = decodeJwtExp(token),
           exp.timeIntervalSinceNow < 60 {
            AppLogger.shared.log(
                "[Auth] token expires in \(Int(exp.timeIntervalSinceNow))s — refreshing before \(label)",
                level: .info, category: "Auth"
            )
            if await coalescedRefresh(), let fresh = accessToken {
                request.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
            }
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            AppLogger.shared.log("[HTTP] ← NETWORK_ERROR \(label) (\(elapsedMs)ms) \(error.localizedDescription)", level: .error, category: "HTTP")
            throw AgorAPIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AgorAPIError.networkError(URLError(.badServerResponse))
        }

        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        let statusCode = httpResponse.statusCode

        // Handle 401: try JWT refresh → silentReAuth → give up
        if statusCode == 401 && attemptRefresh {
            AppLogger.shared.log("[HTTP] ← 401 \(label) (\(elapsedMs)ms) — attempting auth recovery", level: .debug, category: "HTTP")
            var tokenRefreshed = false

            // Step 1: JWT refresh if we have a refresh token
            if refreshToken != nil {
                tokenRefreshed = await coalescedRefresh()
                if !tokenRefreshed {
                    refreshToken = nil
                    AppLogger.shared.log("[HTTP] JWT refresh failed — falling back to silent re-auth", level: .warning, category: "Auth")
                }
            }

            // Step 2: silentReAuth if JWT refresh failed or no refresh token
            if !tokenRefreshed, let reAuth = onSilentReAuth {
                do {
                    try await reAuth()
                    tokenRefreshed = true
                    AppLogger.shared.log("[HTTP] Silent re-auth succeeded — retrying request", level: .info, category: "Auth")
                } catch {
                    AppLogger.shared.log("[HTTP] Silent re-auth failed — session expired", level: .error, category: "Auth")
                }
            }

            if tokenRefreshed {
                var retryRequest = request
                if let token = accessToken {
                    retryRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                return try await executeRaw(retryRequest, attemptRefresh: false)
            } else {
                Task { @MainActor [weak self] in
                    self?.onSessionExpired?()
                }
                throw AgorAPIError.tokenRefreshFailed
            }
        }

        if statusCode == 401, !attemptRefresh {
            // A 401 that survives a successful refresh means the new token was
            // rejected too — the interesting case, and previously invisible
            // because the error only carried the status code.
            let body = String(data: data, encoding: .utf8) ?? "no body"
            let expiry = accessToken.flatMap(decodeJwtExp).map { Int($0.timeIntervalSinceNow) }
            AppLogger.shared.log(
                "[Auth] 401 persisted after refresh on \(label) — token expires in \(expiry.map(String.init) ?? "?")s, body=\(AppLogger.scrub(body))",
                level: .error, category: "Auth"
            )
        }

        guard (200...299).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8)
            let truncatedBody = body.map { $0.count > 300 ? String($0.prefix(300)) + "..." : $0 } ?? "no body"
            AppLogger.shared.log("[HTTP] ← \(statusCode) \(label) (\(elapsedMs)ms, \(data.count) bytes) body=\(truncatedBody)", level: .error, category: "HTTP")
            throw AgorAPIError.httpError(statusCode: statusCode, body: body)
        }

        AppLogger.shared.log("[HTTP] ← \(statusCode) \(label) (\(elapsedMs)ms, \(data.count) bytes)", level: .debug, category: "HTTP")
        return data
    }

    // MARK: - Token Refresh

    /// Coalesce concurrent refreshes into a single network call. Returns true on success.
    private func coalescedRefresh() async -> Bool {
        refreshLock.lock()
        if let existing = inFlightRefresh {
            refreshLock.unlock()
            return await existing.value
        }
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            do { try await self.refreshAccessToken(); return true }
            catch { return false }
        }
        inFlightRefresh = task
        refreshLock.unlock()
        let result = await task.value
        refreshLock.lock(); inFlightRefresh = nil; refreshLock.unlock()
        return result
    }

    private func refreshAccessToken() async throws {
        guard let refresh = refreshToken else { throw AgorAPIError.tokenRefreshFailed }
        AppLogger.shared.log("Refreshing access token", category: "Auth")
        isRefreshing = true
        defer { isRefreshing = false }

        struct RefreshRequest: Codable {
            let refreshToken: String
        }

        struct RefreshResponse: Codable {
            let accessToken: String
            let refreshToken: String?
            let user: User?
        }

        let body = RefreshRequest(refreshToken: refresh)
        var request = try buildRequest(path: "/authentication/refresh", method: "POST")
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Don't send the expired access token for refresh
        request.setValue(nil, forHTTPHeaderField: "Authorization")

        let data = try await executeRaw(request, attemptRefresh: false)
        let authResponse = try decoder.decode(RefreshResponse.self, from: data)

        accessToken = authResponse.accessToken
        if let newRefresh = authResponse.refreshToken {
            refreshToken = newRefresh
            KeychainHelper.save(newRefresh, for: .refreshToken)
        }
        KeychainHelper.save(authResponse.accessToken, for: .accessToken)

        if let exp = decodeJwtExp(authResponse.accessToken) {
            AppLogger.shared.log(
                "[Auth] new access token valid for \(Int(exp.timeIntervalSinceNow))s",
                level: .info, category: "Auth"
            )
        }

        // Also persist to per-profile storage so restoreSession() finds fresh tokens
        let pm = ServerProfileManager.shared
        if let profileId = pm.activeProfileId {
            pm.saveToken(authResponse.accessToken, key: .accessToken, profileId: profileId)
            if let newRefresh = authResponse.refreshToken {
                pm.saveToken(newRefresh, key: .refreshToken, profileId: profileId)
            }
        }

        let notify = onTokenRefreshed
        Task { @MainActor in notify?() }
    }

    // MARK: - File Upload (multipart/form-data)

    /// Decoded leniently: daemon versions differ on which of these keys they
    /// send, and the only field the app actually uses is the path. Failing the
    /// whole upload because `success` or `mimeType` was absent reported a
    /// finished upload as a failure.
    struct UploadedFile: Decodable {
        let filename: String
        let path: String
        let size: Int
        let mimeType: String

        private enum CodingKeys: String, CodingKey {
            case filename, name, originalname
            case path, relativePath, filepath, destination
            case size
            case mimeType, mimetype, type
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let name = try c.decodeIfPresent(String.self, forKey: .filename)
                ?? c.decodeIfPresent(String.self, forKey: .name)
                ?? c.decodeIfPresent(String.self, forKey: .originalname)
            let resolvedPath = try c.decodeIfPresent(String.self, forKey: .path)
                ?? c.decodeIfPresent(String.self, forKey: .relativePath)
                ?? c.decodeIfPresent(String.self, forKey: .filepath)
                ?? c.decodeIfPresent(String.self, forKey: .destination)

            guard let path = resolvedPath ?? name else {
                throw DecodingError.dataCorruptedError(
                    forKey: .path, in: c,
                    debugDescription: "upload response carried neither a path nor a filename"
                )
            }
            self.path = path
            self.filename = name ?? (path.components(separatedBy: "/").last ?? path)
            self.size = (try? c.decodeIfPresent(Int.self, forKey: .size)) .flatMap { $0 } ?? 0
            self.mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
                ?? c.decodeIfPresent(String.self, forKey: .mimetype)
                ?? c.decodeIfPresent(String.self, forKey: .type)
                ?? "application/octet-stream"
        }
    }

    struct UploadResponse: Decodable {
        let success: Bool
        let files: [UploadedFile]

        private enum CodingKeys: String, CodingKey {
            case success, files, file, data, uploaded
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            success = try c.decodeIfPresent(Bool.self, forKey: .success) ?? true
            if let files = try c.decodeIfPresent([UploadedFile].self, forKey: .files) {
                self.files = files
            } else if let files = try c.decodeIfPresent([UploadedFile].self, forKey: .uploaded) {
                self.files = files
            } else if let files = try c.decodeIfPresent([UploadedFile].self, forKey: .data) {
                self.files = files
            } else if let single = try c.decodeIfPresent(UploadedFile.self, forKey: .file) {
                self.files = [single]
            } else {
                // A bare object response: the whole payload describes one file.
                self.files = [try UploadedFile(from: decoder)]
            }
        }
    }

    func uploadFile(sessionId: String, fileData: Data, fileName: String, mimeType: String) async throws -> UploadResponse {
        guard !baseURL.isEmpty else { throw AgorAPIError.invalidURL }
        // The daemon validates this against worktree | temp | global and fails
        // the whole request on anything else. "branch" is the newer name for a
        // worktree everywhere *except* here, and sending it rejected every
        // upload before multer ever wrote a file.
        guard let url = URL(string: "\(baseURL)/sessions/\(sessionId)/upload?destination=worktree") else {
            throw AgorAPIError.invalidURL
        }

        // Uploads don't go through executeRaw, so nothing here refreshes an
        // expiring token or retries a 401 — an upload attempted near expiry used
        // to fail outright with no recovery.
        if let token = accessToken, let exp = decodeJwtExp(token), exp.timeIntervalSinceNow < 120 {
            AppLogger.shared.log("[Auth] token expires in \(Int(exp.timeIntervalSinceNow))s — refreshing before upload", level: .info, category: "Auth")
            _ = await coalescedRefresh()
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"files\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        func makeRequest() -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            if let token = accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            // A photo over a phone link needs longer than the 30s default, which
            // surfaced as URLError -1001 "request timed out".
            request.timeoutInterval = 120
            request.httpBody = body
            return request
        }

        AppLogger.shared.log("[HTTP] → POST /sessions/\(String(sessionId.prefix(8)))/upload (\(fileName), \(fileData.count) bytes)", level: .info, category: "HTTP")

        let start = Date()
        var (data, response) = try await session.data(for: makeRequest())
        var statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode == 401 {
            AppLogger.shared.log("[HTTP] ← 401 upload — attempting auth recovery", level: .warning, category: "HTTP")
            var recovered = false
            if refreshToken != nil {
                recovered = await coalescedRefresh()
            }
            if !recovered, let reAuth = onSilentReAuth {
                recovered = (try? await reAuth()) != nil
            }
            if recovered {
                (data, response) = try await session.data(for: makeRequest())
                statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            }
        }

        guard (200...299).contains(statusCode) else {
            let responseBody = String(data: data, encoding: .utf8)
            AppLogger.shared.log(
                "[HTTP] ← \(statusCode) upload \(fileName) (\(Int(Date().timeIntervalSince(start) * 1000))ms) body=\(AppLogger.scrub(responseBody ?? "no body"))",
                level: .error, category: "HTTP"
            )
            throw AgorAPIError.httpError(statusCode: statusCode, body: responseBody)
        }

        // Logged unconditionally: the shape of this response is the one thing
        // that has repeatedly not matched what the app expects.
        AppLogger.shared.log(
            "[HTTP] ← \(statusCode) upload \(fileName) OK (\(Int(Date().timeIntervalSince(start) * 1000))ms) body=\(AppLogger.scrub(String(data: data, encoding: .utf8) ?? "<binary \(data.count) bytes>"))",
            level: .info, category: "HTTP"
        )

        do {
            return try decoder.decode(UploadResponse.self, from: data)
        } catch {
            // The upload itself succeeded — say so, instead of reporting a
            // decode failure as if the file never made it.
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            AppLogger.shared.log(
                "[HTTP] upload response decode failed: \(error) body=\(AppLogger.scrub(raw))",
                level: .error, category: "HTTP"
            )
            throw AgorAPIError.decodingError(error)
        }
    }

    // MARK: - Token Refresh (public — used by SocketService to refresh after socket auth failure)

    func tryRefreshToken() async -> Bool {
        await coalescedRefresh()
    }

    /// Proactively refresh token if it expires within `bufferSeconds`.
    /// Returns true if token was refreshed or still valid, false on failure.
    @discardableResult
    func refreshTokenIfNeeded(bufferSeconds: TimeInterval = 120) async -> Bool {
        guard let token = accessToken else { return false }
        if let exp = decodeJwtExp(token), exp.timeIntervalSinceNow < bufferSeconds {
            AppLogger.shared.log("[Auth] token expires in \(Int(exp.timeIntervalSinceNow))s — proactive refresh", level: .info, category: "Auth")
            return await tryRefreshToken()
        }
        return true // token still valid
    }

    /// Decode JWT exp claim without external dependencies.
    private func decodeJwtExp(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to multiple of 4
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    // MARK: - Health Check (silent — no logging since it polls frequently)

    func healthCheck() async -> Bool {
        do {
            let request = try buildRequest(path: "/health", method: "GET")
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
