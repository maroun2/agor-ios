import Foundation
import Security

/// Loads the selectable session list for the widget configuration picker.
///
/// App Groups aren't available under free-provisioning signing, so the widget can't
/// read the app's shared UserDefaults. Instead it reads the auth token + server URL
/// from a shared keychain access group (mirrored by the app via WidgetCredentialStore)
/// and fetches the session list directly from the daemon.
enum WidgetSessionLoader {
    static let accessGroup = "L94RKR8S54.com.agor.shared"
    static let service = "live.agor.widget"
    static let account = "widget_creds"

    private struct Credentials: Codable {
        let token: String
        let serverURL: String
    }

    private static func loadCredentials() -> Credentials? {
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
              let creds = try? JSONDecoder().decode(Credentials.self, from: data) else { return nil }
        return creds
    }

    private struct SessionsResponse: Decodable { let data: [SessionRow] }
    private struct SessionRow: Decodable {
        let session_id: String
        let title: String?
        let description: String?
        let archived: Bool?
    }

    struct PickerSession { let id: String; let title: String }

    /// Fetch up to 50 most-recent non-archived sessions from the daemon.
    /// Returns [] on any failure (no creds, network error, auth error) — the picker
    /// then shows an empty list rather than crashing.
    static func fetchSessions() async -> [PickerSession] {
        guard let creds = loadCredentials(),
              var comps = URLComponents(string: "\(creds.serverURL)/sessions") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "$limit", value: "200"),
            URLQueryItem(name: "$sort[last_updated]", value: "-1"),
        ]
        guard let url = comps.url else { return [] }

        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let decoded = try JSONDecoder().decode(SessionsResponse.self, from: data)
            return decoded.data
                .filter { $0.archived != true }
                .prefix(50)
                .map { row in
                    let title: String
                    if let t = row.title, !t.isEmpty { title = t }
                    else if let d = row.description, !d.isEmpty { title = d }
                    else { title = "Session \(row.session_id.prefix(6))" }
                    return PickerSession(id: row.session_id, title: title)
                }
        } catch {
            return []
        }
    }
}
