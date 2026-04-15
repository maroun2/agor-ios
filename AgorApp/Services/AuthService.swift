import Foundation

// MARK: - Auth Response

struct AuthResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let authentication: AuthInfo?
    let user: User?

    enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, authentication, user
    }
}

struct AuthInfo: Codable {
    let strategy: String?
    let accessToken: String?
    let payload: AuthPayload?
}

struct AuthPayload: Codable {
    let iat: Int?
    let exp: Int?
    let aud: String?
    let iss: String?
    let sub: String?
    let jti: String?
}

// MARK: - Auth Service

@Observable
final class AuthService {
    var isAuthenticated = false
    var currentUser: User?
    var isLoading = false
    var error: String?

    private let client: AgorClient

    init(client: AgorClient) {
        self.client = client
        restoreSession()
    }

    // MARK: - Login

    func login(daemonURL: String, email: String, password: String) async throws {
        AppLogger.shared.log("Login attempt for \(email) at \(daemonURL)", category: "Auth")
        isLoading = true
        error = nil
        defer { isLoading = false }

        // Normalize URL
        var url = daemonURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url.removeLast() }
        let rawInput = url

        // Strip path components (e.g., /ui)
        if let components = URLComponents(string: url.hasPrefix("http") ? url : "http://\(url)"),
           let host = components.host {
            let scheme = components.scheme ?? "http"
            if let explicitPort = components.port {
                // User provided an explicit port — always use it
                url = "\(scheme)://\(host):\(explicitPort)"
            } else if scheme == "https" {
                // HTTPS with no port — omit port (443 is implicit)
                url = "\(scheme)://\(host)"
            } else {
                // HTTP with no port — default to 3030 (dev default)
                url = "\(scheme)://\(host):3030"
            }
        } else {
            if !url.hasPrefix("http") { url = "http://\(url)" }
            // Add default port only for http if none specified
            if let parsed = URLComponents(string: url), parsed.port == nil,
               parsed.scheme != "https" {
                url = url + ":3030"
            }
        }
        AppLogger.shared.log("[Auth] normalizeURL: \"\(rawInput)\" → \"\(url)\"", level: .debug, category: "Auth")

        // Validate connection via health check, try both http and https
        client.baseURL = url
        var validated = await client.healthCheck()
        if validated {
            AppLogger.shared.log("[Auth] healthCheck \(url) → OK", level: .info, category: "Auth")
        } else {
            AppLogger.shared.log("[Auth] healthCheck \(url) → failed", level: .debug, category: "Auth")
        }
        if !validated && url.hasPrefix("http://") {
            // When upgrading to HTTPS, strip the dev default port (:3030)
            // since HTTPS typically runs on 443
            var httpsURL = url.replacingOccurrences(of: "http://", with: "https://")
            httpsURL = httpsURL.replacingOccurrences(of: ":3030", with: "")
            AppLogger.shared.log("[Auth] trying HTTPS fallback: \(httpsURL)", level: .debug, category: "Auth")
            client.baseURL = httpsURL
            if await client.healthCheck() {
                AppLogger.shared.log("[Auth] healthCheck \(httpsURL) → OK", level: .info, category: "Auth")
                url = httpsURL
                validated = true
            } else {
                AppLogger.shared.log("[Auth] healthCheck \(httpsURL) → failed", level: .debug, category: "Auth")
                client.baseURL = url // revert
            }
        }

        struct LoginRequest: Codable {
            let strategy: String
            let email: String
            let password: String
        }

        let body = LoginRequest(strategy: "local", email: email, password: password)
        let response: AuthResponse = try await client.post("/authentication", body: body)

        client.accessToken = response.accessToken
        client.refreshToken = response.refreshToken
        currentUser = response.user
        isAuthenticated = true
        AppLogger.shared.log("Login successful for \(email)", category: "Auth")

        // Persist
        KeychainHelper.save(url, for: .daemonURL)
        KeychainHelper.save(response.accessToken, for: .accessToken)
        AppLogger.shared.log("[Auth] token saved to keychain", level: .info, category: "Auth")
        if let refresh = response.refreshToken {
            KeychainHelper.save(refresh, for: .refreshToken)
            AppLogger.shared.log("[Auth] refresh token saved to keychain", level: .debug, category: "Auth")
        }
        if let userId = response.user?.userId {
            KeychainHelper.save(userId, for: .userId)
        }
        if let email = response.user?.email {
            KeychainHelper.save(email, for: .userEmail)
        }
    }

    // MARK: - Logout

    func logout() {
        AppLogger.shared.log("User logged out", category: "Auth")
        client.accessToken = nil
        client.refreshToken = nil
        client.baseURL = ""
        currentUser = nil
        isAuthenticated = false
        KeychainHelper.deleteAll()
        AppLogger.shared.log("[Auth] keychain: all tokens cleared", level: .info, category: "Auth")
    }

    // MARK: - Session Restore

    private func restoreSession() {
        guard let url = KeychainHelper.load(.daemonURL),
              let token = KeychainHelper.load(.accessToken) else {
            AppLogger.shared.log("[Auth] keychain: no saved session found", level: .debug, category: "Auth")
            return
        }

        client.baseURL = url
        client.accessToken = token
        client.refreshToken = KeychainHelper.load(.refreshToken)
        isAuthenticated = true

        // Restore user from keychain (minimal info)
        if let userId = KeychainHelper.load(.userId),
           let email = KeychainHelper.load(.userEmail) {
            AppLogger.shared.log("[Auth] keychain: loaded saved session for \(email)", level: .info, category: "Auth")
            currentUser = User(
                userId: userId,
                email: email,
                name: nil,
                emoji: nil,
                avatar: nil,
                role: nil,
                onboardingCompleted: nil,
                mustChangePassword: nil,
                createdAt: nil,
                updatedAt: nil,
                unixUsername: nil
            )
        } else {
            AppLogger.shared.log("[Auth] keychain: session restored for \(url) (no user info cached)", level: .debug, category: "Auth")
        }
    }

    // MARK: - Fetch Current User

    func fetchCurrentUser() async {
        guard isAuthenticated else { return }
        do {
            let response: PaginatedResponse<User> = try await client.getPaginated("/users", query: ["$limit": "1"])
            if let user = response.data.first {
                currentUser = user
            }
        } catch {
            AppLogger.shared.log("[Auth] fetchCurrentUser failed: \(error.localizedDescription)", level: .error, category: "Auth")
            // Token refresh failed — session is dead, clear tokens and force re-login
            // Keep daemonURL and email in keychain so the login form can pre-populate them
            if case AgorAPIError.tokenRefreshFailed = error {
                AppLogger.shared.log("[Auth] token refresh failed on startup — clearing tokens, forcing re-login", level: .error, category: "Auth")
                client.accessToken = nil
                client.refreshToken = nil
                currentUser = nil
                isAuthenticated = false
                KeychainHelper.delete(.accessToken)
                KeychainHelper.delete(.refreshToken)
            }
        }
    }
}
