import WidgetKit

// MARK: - Timeline Entry

struct SessionTimelineEntry: TimelineEntry {
    let date: Date
    let sessionData: WidgetSessionData?
    let configuration: SessionConfigurationIntent
}

// MARK: - Timeline Provider

struct SessionTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SessionTimelineEntry {
        SessionTimelineEntry(
            date: Date(),
            sessionData: WidgetSessionData(
                sessionId: "preview",
                sessionTitle: "My Session",
                lastMessage: "Working on the new feature implementation...",
                lastMessageRole: "assistant",
                lastUpdated: Date(),
                status: "running"
            ),
            configuration: SessionConfigurationIntent()
        )
    }

    func snapshot(for configuration: SessionConfigurationIntent, in context: Context) async -> SessionTimelineEntry {
        SessionTimelineEntry(
            date: Date(),
            sessionData: resolveSession(for: configuration),
            configuration: configuration
        )
    }

    func timeline(for configuration: SessionConfigurationIntent, in context: Context) async -> Timeline<SessionTimelineEntry> {
        let entry = SessionTimelineEntry(
            date: Date(),
            sessionData: resolveSession(for: configuration),
            configuration: configuration
        )
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
    }

    private func resolveSession(for configuration: SessionConfigurationIntent) -> WidgetSessionData? {
        guard let id = configuration.session?.id else { return nil }
        return WidgetDataStore.readSessions().first { $0.sessionId == id }
    }
}
