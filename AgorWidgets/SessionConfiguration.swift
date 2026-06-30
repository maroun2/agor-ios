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
    /// Read the session list the app writes to the shared App Group.
    /// NOTE: App Groups require a paid Apple Developer account; under free-provisioning
    /// signing this returns empty (the app and widget can't share storage), so the picker
    /// stays empty until an App Group capability is added. See ONBOARDING/notes.
    private func pickerEntities() -> [SessionEntity] {
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
