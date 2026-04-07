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
            ServerProfileManager.shared.migrateFromKeychain(url: url)
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

            // Also save to standard keychain keys for compatibility
            KeychainHelper.save(profile.url, for: .daemonURL)
            KeychainHelper.save(token, for: .accessToken)
            if let refresh = client.refreshToken {
                KeychainHelper.save(refresh, for: .refreshToken)
            }

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

    var isAuthenticated: Bool { authService.isAuthenticated }
    var currentUser: User? { authService.currentUser }
    var daemonURL: String { client.baseURL }
}
