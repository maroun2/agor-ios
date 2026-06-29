import Foundation

// Mirrors WidgetPickerSession in WidgetDataWriter (app target) — must stay in sync.
struct WidgetPickerSession: Codable, Identifiable {
    var id: String { sessionId }
    let sessionId: String
    let sessionTitle: String
}

// Shared data model between main app and widget extension.
// Main app writes via WidgetDataWriter; widget reads here.
struct WidgetSessionData: Codable, Identifiable {
    var id: String { sessionId }
    let sessionId: String
    let sessionTitle: String
    let lastMessage: String        // plain text, up to 300 chars
    let lastMessageRole: String    // "user" or "assistant"
    let lastUpdated: Date
    let status: String             // "idle", "running", etc.
}

enum WidgetDataStore {
    static let appGroupID = "group.com.agor.AgorApp"
    static let sessionsKey = "widget.sessions"
    static let serverURLKey = "widget.serverURL"
    static let pickerSessionsKey = "widget.pickerSessions"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func readSessions() -> [WidgetSessionData] {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: sessionsKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([WidgetSessionData].self, from: data)) ?? []
    }

    static func readServerURL() -> String? {
        sharedDefaults?.string(forKey: serverURLKey)
    }

    static func readPickerSessions() -> [WidgetPickerSession] {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: pickerSessionsKey) else { return [] }
        return (try? JSONDecoder().decode([WidgetPickerSession].self, from: data)) ?? []
    }
}
