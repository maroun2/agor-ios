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
    func entities(for identifiers: [String]) async throws -> [SessionEntity] {
        WidgetDataStore.readSessions()
            .filter { identifiers.contains($0.sessionId) }
            .map { SessionEntity(id: $0.sessionId, title: $0.sessionTitle) }
    }

    func suggestedEntities() async throws -> [SessionEntity] {
        WidgetDataStore.readSessions().map {
            SessionEntity(id: $0.sessionId, title: $0.sessionTitle)
        }
    }
}

// MARK: - Configuration Intent

struct SessionConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Session"
    static var description = IntentDescription("Choose a favorited session")

    @Parameter(title: "Session")
    var session: SessionEntity?
}
