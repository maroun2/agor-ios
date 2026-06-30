import Foundation

/// Minimal self-contained network client for the widget extension.
///
/// The widget can't read the app's stored login (App Groups / shared keychain are
/// unavailable under free-provisioning signing), so the bigger widget authenticates
/// itself with credentials the user enters in the widget's configuration.
enum WidgetAPI {
    struct Credentials {
        let serverURL: String
        let email: String
        let password: String
    }

    struct SessionRow: Decodable {
        let session_id: String
        let title: String?
        let description: String?
        let status: String?
        let archived: Bool?
        let last_updated: String?
    }

    struct MessageRow: Decodable {
        let role: String?
        let content_preview: String?
        let created_at: String?
    }

    private struct AuthResponse: Decodable { let accessToken: String }
    private struct SessionsResponse: Decodable { let data: [SessionRow] }
    private struct MessagesResponse: Decodable { let data: [MessageRow] }

    // MARK: - Public

    /// Fetch up to 50 most-recent non-archived sessions (id + title) for the config picker.
    static func fetchSessions(_ creds: Credentials) async -> [SessionRow] {
        guard let token = await authenticate(creds),
              var comps = URLComponents(string: "\(normalized(creds.serverURL))/sessions") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "$limit", value: "200"),
            URLQueryItem(name: "$sort[last_updated]", value: "-1"),
        ]
        guard let url = comps.url,
              let (data, resp) = try? await URLSession.shared.data(for: authed(url, token)),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(SessionsResponse.self, from: data) else { return [] }
        return decoded.data.filter { $0.archived != true }
    }

    /// Fetch a single session plus its latest message for the monitor widget.
    static func fetchSessionDetail(_ creds: Credentials, sessionId: String) async -> (session: SessionRow, lastMessage: MessageRow?)? {
        guard let token = await authenticate(creds),
              let sUrl = URL(string: "\(normalized(creds.serverURL))/sessions/\(sessionId)") else { return nil }
        guard let (sData, sResp) = try? await URLSession.shared.data(for: authed(sUrl, token)),
              (sResp as? HTTPURLResponse)?.statusCode == 200,
              let session = try? JSONDecoder().decode(SessionRow.self, from: sData) else { return nil }

        var lastMessage: MessageRow?
        if var mComps = URLComponents(string: "\(normalized(creds.serverURL))/messages") {
            mComps.queryItems = [
                URLQueryItem(name: "session_id", value: sessionId),
                URLQueryItem(name: "$limit", value: "1"),
                URLQueryItem(name: "$sort[created_at]", value: "-1"),
            ]
            if let mUrl = mComps.url,
               let (mData, mResp) = try? await URLSession.shared.data(for: authed(mUrl, token)),
               (mResp as? HTTPURLResponse)?.statusCode == 200,
               let decoded = try? JSONDecoder().decode(MessagesResponse.self, from: mData) {
                lastMessage = decoded.data.first
            }
        }
        return (session, lastMessage)
    }

    static func title(_ s: SessionRow) -> String {
        if let t = s.title, !t.isEmpty { return t }
        if let d = s.description, !d.isEmpty { return d }
        return "Session \(s.session_id.prefix(6))"
    }

    /// Accept a raw session id, an agor:// deep link, or a web URL and return just the id.
    static func extractSessionId(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let range = s.range(of: "session/") {
            s = String(s[range.upperBound...])
        }
        // Drop any trailing path/query (e.g. "/voice", "?x=y")
        if let slash = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            s = String(s[..<slash])
        }
        return s.isEmpty ? nil : s
    }

    // MARK: - Internal

    private static func authenticate(_ creds: Credentials) async -> String? {
        guard !creds.email.isEmpty, !creds.password.isEmpty,
              let url = URL(string: "\(normalized(creds.serverURL))/authentication") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 12
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "strategy": "local", "email": creds.email, "password": creds.password,
        ])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode, (200...299).contains(code),
              let auth = try? JSONDecoder().decode(AuthResponse.self, from: data) else { return nil }
        return auth.accessToken
    }

    private static func authed(_ url: URL, _ token: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private static func normalized(_ url: String) -> String {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        if !u.hasPrefix("http://") && !u.hasPrefix("https://") { u = "https://\(u)" }
        return u
    }
}
