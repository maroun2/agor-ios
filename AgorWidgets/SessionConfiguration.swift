import AppIntents
import WidgetKit

// MARK: - Session Entity

struct SessionEntity: AppEntity {
    var id: String
    var title: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Session"

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    static var defaultQuery = SessionEntityQuery()
}

// MARK: - Entity Query

struct SessionEntityQuery: EntityQuery {
    /// Read the session list the app mirrored into the shared keychain. Falls back to the
    /// App Group store (empty under free-provisioning signing).
    private func pickerEntities() -> [SessionEntity] {
        let stored = WidgetSessionLoader.loadSessions()
        if !stored.isEmpty {
            return stored.map { SessionEntity(id: $0.sessionId, title: $0.sessionTitle) }
        }
        let picker = WidgetDataStore.readPickerSessions()
        if !picker.isEmpty {
            return picker.map { SessionEntity(id: $0.sessionId, title: $0.sessionTitle) }
        }
        return WidgetDataStore.readSessions().map { SessionEntity(id: $0.sessionId, title: $0.sessionTitle) }
    }

    func entities(for identifiers: [String]) async throws -> [SessionEntity] {
        pickerEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [SessionEntity] {
        pickerEntities()
    }
}

// MARK: - Configuration Intent

struct SessionConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Session"
    static var description = IntentDescription("Choose a favorited session")

    @Parameter(title: "Session")
    var session: SessionEntity?
}
