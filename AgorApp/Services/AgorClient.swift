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
        case .decodingError(let err): "Decoding error: \(err.localizedDescription)"
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

    private let session: URLSession
    private let decoder = JSONDecoder.agor
    private let encoder = JSONEncoder.agor

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
            let truncated = bodyString.count > 500 ? String(bodyString.prefix(500)) + "..." : bodyString
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

        // Handle 401 with token refresh
        if statusCode == 401 && attemptRefresh && refreshToken != nil {
            AppLogger.shared.log("[HTTP] ← 401 \(label) (\(elapsedMs)ms, \(data.count) bytes) — attempting token refresh", level: .debug, category: "HTTP")
            do {
                try await refreshAccessToken()
                // Retry with new token
                var retryRequest = request
                if let token = accessToken {
                    retryRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                return try await executeRaw(retryRequest, attemptRefresh: false)
            } catch {
                throw AgorAPIError.tokenRefreshFailed
            }
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

    private func refreshAccessToken() async throws {
        guard !isRefreshing, let refresh = refreshToken else { throw AgorAPIError.tokenRefreshFailed }
        AppLogger.shared.log("Refreshing access token", category: "Auth")
        isRefreshing = true
        defer { isRefreshing = false }

        struct RefreshRequest: Codable {
            let strategy: String
            let refreshToken: String
        }

        struct AuthResponse: Codable {
            let accessToken: String
            let refreshToken: String?
            let user: User?
        }

        let body = RefreshRequest(strategy: "jwt", refreshToken: refresh)
        var request = try buildRequest(path: "/authentication", method: "POST")
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Don't send the expired access token for refresh
        request.setValue(nil, forHTTPHeaderField: "Authorization")

        let data = try await executeRaw(request, attemptRefresh: false)
        let authResponse = try decoder.decode(AuthResponse.self, from: data)

        accessToken = authResponse.accessToken
        if let newRefresh = authResponse.refreshToken {
            refreshToken = newRefresh
            KeychainHelper.save(newRefresh, for: .refreshToken)
        }
        KeychainHelper.save(authResponse.accessToken, for: .accessToken)
    }

    // MARK: - File Upload (multipart/form-data)

    struct UploadedFile: Codable {
        let filename: String
        let path: String
        let size: Int
        let mimeType: String
    }

    struct UploadResponse: Codable {
        let success: Bool
        let files: [UploadedFile]
    }

    func uploadFile(sessionId: String, fileData: Data, fileName: String, mimeType: String) async throws -> UploadResponse {
        guard !baseURL.isEmpty else { throw AgorAPIError.invalidURL }
        guard let url = URL(string: "\(baseURL)/sessions/\(sessionId)/upload?destination=worktree") else {
            throw AgorAPIError.invalidURL
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"files\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        AppLogger.shared.log("[HTTP] → POST /sessions/\(String(sessionId.prefix(8)))/upload (\(fileName), \(fileData.count) bytes)", level: .debug, category: "HTTP")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseBody = String(data: data, encoding: .utf8)
            throw AgorAPIError.httpError(statusCode: statusCode, body: responseBody)
        }

        return try decoder.decode(UploadResponse.self, from: data)
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
