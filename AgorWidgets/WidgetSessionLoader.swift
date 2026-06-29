import Foundation
import Security

/// Loads the selectable session list for the widget configuration picker.
///
/// App Groups aren't available under free-provisioning signing, so the widget can't
/// read the app's shared UserDefaults. Instead the app mirrors the session list into a
/// shared keychain access group (WidgetSessionStore) and we read it here — no network.
enum WidgetSessionLoader {
    static let accessGroup = "L94RKR8S54.com.agor.shared"
    static let service = "live.agor.widget"
    static let account = "widget_sessions"

    struct StoredSession: Codable {
        let sessionId: String
        let sessionTitle: String
    }

    static func loadSessions() -> [StoredSession] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let sessions = try? JSONDecoder().decode([StoredSession].self, from: data) else { return [] }
        return sessions
    }
}
