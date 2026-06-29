import Foundation
import Security

/// Bridges auth credentials to the widget extension.
///
/// App Groups aren't available under free-provisioning signing (they need a paid
/// account), so the shared App Group UserDefaults the widget normally reads is a
/// no-op on device. Keychain sharing, however, IS entitled (keychain-access-groups:
/// <team>.*), so we mirror the current token + server URL into a shared keychain
/// access group. The widget reads them from there to fetch the session list.
enum WidgetCredentialStore {
    /// Shared access group — permitted by the `L94RKR8S54.*` keychain-access-groups
    /// entitlement that both the app and widget are signed with.
    static let accessGroup = "L94RKR8S54.com.agor.shared"
    static let service = "live.agor.widget"
    static let account = "widget_creds"

    struct Credentials: Codable {
        let token: String
        let serverURL: String
    }

    /// Mirror the current credentials for the widget. Clears them when logged out.
    static func save(token: String?, serverURL: String) {
        guard let token, !token.isEmpty, !serverURL.isEmpty else {
            clear()
            return
        }
        guard let data = try? JSONEncoder().encode(Credentials(token: token, serverURL: serverURL)) else { return }

        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            AppLogger.shared.log("[Widget] credential store write failed: \(status)", level: .warning, category: "Widget")
        }
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
