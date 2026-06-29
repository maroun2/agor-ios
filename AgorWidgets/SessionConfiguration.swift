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
    /// Fetch sessions live from the daemon (via shared-keychain credentials). Falls back
    /// to the App Group store, which is empty under free-provisioning signing.
    private func pickerEntities() async -> [SessionEntity] {
        let live = await WidgetSessionLoader.fetchSessions()
        if !live.isEmpty {
            return live.map { SessionEntity(id: $0.id, title: $0.title) }
        }
        let picker = WidgetDataStore.readPickerSessions()
        if !picker.isEmpty {
            return picker.map { SessionEntity(id: $0.sessionId, title: $0.sessionTitle) }
        }
        return WidgetDataStore.readSessions().map { SessionEntity(id: $0.sessionId, title: $0.sessionTitle) }
    }

    func entities(for identifiers: [String]) async throws -> [SessionEntity] {
        await pickerEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [SessionEntity] {
        await pickerEntities()
    }
}

// MARK: - Configuration Intent

struct SessionConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Session"
    static var description = IntentDescription("Choose a favorited session")

    @Parameter(title: "Session")
    var session: SessionEntity?
}
