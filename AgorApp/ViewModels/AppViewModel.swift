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
    }

    var isAuthenticated: Bool { authService.isAuthenticated }
    var currentUser: User? { authService.currentUser }
    var daemonURL: String { client.baseURL }
}
