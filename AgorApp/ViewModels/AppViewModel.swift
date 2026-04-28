import Foundation
import SwiftUI

@Observable
final class AppViewModel {
    let client: AgorClient
    let authService: AuthService

    var connectionError: String?

    init() {
        let client = AgorClient()
        self.client = client
        self.authService = AuthService(client: client)
        BackgroundSessionPoller.shared.configure(client: client)

        // Migrate existing keychain URL to server profiles
        if let url = KeychainHelper.load(.daemonURL) {
            let email = KeychainHelper.load(.userEmail) ?? ""
            ServerProfileManager.shared.migrateFromKeychain(url: url, email: email)
        }
    }

    func switchServer(to profile: ServerProfile, socketService: SocketService) async {
        AppLogger.shared.log("[App] Switching to server: \(profile.name) (\(profile.url))", level: .info, category: "App")

        // 1. Disconnect socket
        socketService.disconnect()

        // 2. Save current tokens for current profile
        if let currentId = ServerProfileManager.shared.activeProfileId,
           let token = client.accessToken {
            ServerProfileManager.shared.saveToken(token, key: .accessToken, profileId: currentId)
            if let refresh = client.refreshToken {
                ServerProfileManager.shared.saveToken(refresh, key: .refreshToken, profileId: currentId)
            }
        }

        // 3. Switch active profile
        ServerProfileManager.shared.setActive(profile.id)

        // 4. Update client
        client.baseURL = profile.url

        // 5. Restore tokens for new profile
        if let token = ServerProfileManager.shared.loadToken(key: .accessToken, profileId: profile.id) {
            client.accessToken = token
            client.refreshToken = ServerProfileManager.shared.loadToken(key: .refreshToken, profileId: profile.id)
            authService.isAuthenticated = true

            // Reconnect socket and fetch user
            socketService.connect()
            await authService.fetchCurrentUser()
        } else {
            // No token for this server — need to log in
            client.accessToken = nil
            client.refreshToken = nil
            authService.isAuthenticated = false
            authService.currentUser = nil
        }
    }

    func loginToProfile(url: String, email: String, password: String, profileName: String) async throws {
        try await authService.login(daemonURL: url, email: email, password: password)

        let pm = ServerProfileManager.shared
        let profileId: UUID

        if let existing = pm.profiles.first(where: { $0.url == authService.resolvedURL && $0.email == email }) {
            profileId = existing.id
            var updated = existing
            if !profileName.isEmpty { updated.name = profileName }
            pm.updateProfile(updated)
        } else {
            let profile = ServerProfile(name: profileName.isEmpty ? url : profileName, url: authService.resolvedURL, email: email)
            pm.addProfile(profile)
            profileId = profile.id
        }

        pm.setActive(profileId)
        if let token = client.accessToken {
            pm.saveToken(token, key: .accessToken, profileId: profileId)
        }
        if let refresh = client.refreshToken {
            pm.saveToken(refresh, key: .refreshToken, profileId: profileId)
        }
        if let userId = authService.currentUser?.userId {
            pm.saveToken(userId, key: .userId, profileId: profileId)
        }
        if let userEmail = authService.currentUser?.email {
            pm.saveToken(userEmail, key: .userEmail, profileId: profileId)
        }
        pm.saveToken(password, key: .password, profileId: profileId)
    }

    var isAuthenticated: Bool { authService.isAuthenticated }
    var currentUser: User? { authService.currentUser }
    var daemonURL: String { client.baseURL }
}
