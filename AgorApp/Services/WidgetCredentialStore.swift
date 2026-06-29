import Foundation
import Security

/// Bridges the session list to the widget extension.
///
/// App Groups aren't available under free-provisioning signing (they need a paid
/// account), so the shared App Group UserDefaults the widget normally reads is a
/// no-op on device. Keychain sharing IS entitled (keychain-access-groups: <team>.*),
/// so we store the picker session list in a shared keychain access group and the
/// widget reads it directly — no network.
enum WidgetSessionStore {
    /// Shared access group — covered by the `L94RKR8S54.*` keychain-access-groups
    /// entitlement both the app and widget are signed with.
    static let accessGroup = "L94RKR8S54.com.agor.shared"
    static let service = "live.agor.widget"
    static let account = "widget_sessions"

    static func save(_ sessions: [WidgetPickerSession]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }

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

        guard status == errSecSuccess else {
            AppLogger.shared.log("[Widget] shared keychain write FAILED: \(status) (group \(accessGroup))", level: .warning, category: "Widget")
            return
        }

        // Self-test read-back so the app's exportable debug log shows whether the shared
        // keychain group actually works on this signing (widget logs aren't exportable).
        var readBase = base
        readBase[kSecReturnData as String] = true
        readBase[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let readStatus = SecItemCopyMatching(readBase as CFDictionary, &result)
        let ok = readStatus == errSecSuccess && (result as? Data) != nil
        AppLogger.shared.log("[Widget] wrote \(sessions.count) sessions to shared keychain (readback \(ok ? "OK" : "FAILED \(readStatus)"))", level: .info, category: "Widget")
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
