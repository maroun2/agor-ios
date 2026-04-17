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
    var resolvedURL: String = ""

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
        resolvedURL = url
        AppLogger.shared.log("Login successful for \(email)", category: "Auth")
    }

    // MARK: - Soft Logout (expired token — keep URL/email for re-login)

    func softLogout() {
        AppLogger.shared.log("[Auth] soft logout — clearing expired tokens, keeping URL", level: .info, category: "Auth")
        if let profileId = ServerProfileManager.shared.activeProfileId {
            let pm = ServerProfileManager.shared
            KeychainHelper.deleteRaw(pm.keychainKey(for: profileId, key: .accessToken))
            KeychainHelper.deleteRaw(pm.keychainKey(for: profileId, key: .refreshToken))
        }
        client.accessToken = nil
        client.refreshToken = nil
        currentUser = nil
        isAuthenticated = false
        KeychainHelper.delete(.accessToken)
        KeychainHelper.delete(.refreshToken)
    }

    // MARK: - Logout

    func logout() {
        AppLogger.shared.log("User logged out", category: "Auth")
        if let profileId = ServerProfileManager.shared.activeProfileId {
            ServerProfileManager.shared.deleteTokens(profileId: profileId)
        }
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
        let pm = ServerProfileManager.shared

        // Try active profile first
        if let profile = pm.activeProfile,
           let token = pm.loadToken(key: .accessToken, profileId: profile.id) {
            client.baseURL = profile.url
            client.accessToken = token
            client.refreshToken = pm.loadToken(key: .refreshToken, profileId: profile.id)
            isAuthenticated = true
            if let userId = pm.loadToken(key: .userId, profileId: profile.id),
               let email = pm.loadToken(key: .userEmail, profileId: profile.id) {
                AppLogger.shared.log("[Auth] profile: loaded session for \(email)", level: .info, category: "Auth")
                currentUser = User(userId: userId, email: email, name: nil, emoji: nil, avatar: nil, role: nil, onboardingCompleted: nil, mustChangePassword: nil, createdAt: nil, updatedAt: nil, unixUsername: nil)
            }
            return
        }

        // Fallback: flat keychain (first run after update, before migration ran)
        guard let url = KeychainHelper.load(.daemonURL),
              let token = KeychainHelper.load(.accessToken) else {
            AppLogger.shared.log("[Auth] keychain: no saved session found", level: .debug, category: "Auth")
            return
        }

        client.baseURL = url
        client.accessToken = token
        client.refreshToken = KeychainHelper.load(.refreshToken)
        isAuthenticated = true

        if let userId = KeychainHelper.load(.userId),
           let email = KeychainHelper.load(.userEmail) {
            AppLogger.shared.log("[Auth] keychain: loaded saved session for \(email)", level: .info, category: "Auth")
            currentUser = User(userId: userId, email: email, name: nil, emoji: nil, avatar: nil, role: nil, onboardingCompleted: nil, mustChangePassword: nil, createdAt: nil, updatedAt: nil, unixUsername: nil)
        } else {
            AppLogger.shared.log("[Auth] keychain: session restored for \(url) (no user info cached)", level: .debug, category: "Auth")
        }
    }

    // MARK: - Fetch Current User

    func fetchCurrentUser() async {
        guard isAuthenticated, let userId = currentUser?.userId else { return }
        do {
            let user: User = try await client.get("/users/\(userId)")
            currentUser = user
        } catch {
            // Stay authenticated regardless — network issues, server restarts, token problems
            // Manual logout only (user-initiated via logout button)
            AppLogger.shared.log("[Auth] fetchCurrentUser failed: \(error.localizedDescription)", level: .error, category: "Auth")
        }
    }
}
