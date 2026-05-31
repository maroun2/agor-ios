import Foundation
import WidgetKit

// Mirrors WidgetSessionData in AgorWidgets target — must stay in sync.
struct WidgetSessionData: Codable {
    let sessionId: String
    let sessionTitle: String
    let lastMessage: String        // plain text, up to 300 chars
    let lastMessageRole: String    // "user" or "assistant"
    let lastUpdated: Date
    let status: String
}

enum WidgetDataWriter {
    static let appGroupID = "group.com.agor.AgorApp"
    static let sessionsKey = "widget.sessions"
    static let serverURLKey = "widget.serverURL"

    /// Write favorited sessions to the shared App Group and reload widget timelines.
    static func write(sessions: [WidgetSessionData], serverURL: String) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(sessions) {
            defaults.set(data, forKey: sessionsKey)
        }
        defaults.set(serverURL, forKey: serverURLKey)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
