import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Session entity + dynamic picker (fetched live via entered credentials)

struct WidgetSessionEntity: AppEntity, Identifiable {
    var id: String
    var title: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Session"
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
    static var defaultQuery = WidgetSessionQuery()
}

struct WidgetSessionQuery: EntityQuery {
    // The picker depends on the credentials entered in the same configuration.
    @IntentParameterDependency<SessionMonitorIntent>(\.$serverURL, \.$email, \.$password)
    var config

    private var credentials: WidgetAPI.Credentials? {
        guard let config else { return nil }
        let url = config.serverURL
        let email = config.email
        let password = config.password
        guard !url.isEmpty, !email.isEmpty, !password.isEmpty else { return nil }
        return WidgetAPI.Credentials(serverURL: url, email: email, password: password)
    }

    func suggestedEntities() async throws -> [WidgetSessionEntity] {
        guard let credentials else { return [] }
        let sessions = await WidgetAPI.fetchSessions(credentials)
        return sessions.prefix(50).map { WidgetSessionEntity(id: $0.session_id, title: WidgetAPI.title($0)) }
    }

    func entities(for identifiers: [String]) async throws -> [WidgetSessionEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
}

// MARK: - Configuration

struct SessionMonitorIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Session Monitor"
    static var description = IntentDescription("Show a session's latest message and launch voice mode. Enter your Agor server and login; the widget fetches data itself.")

    @Parameter(title: "Server URL")
    var serverURL: String?

    @Parameter(title: "Email")
    var email: String?

    @Parameter(title: "Password")
    var password: String?

    @Parameter(title: "Session")
    var session: WidgetSessionEntity?

    @Parameter(title: "Session ID (if the picker is empty)")
    var sessionIdManual: String?
}

// MARK: - Timeline

struct SessionMonitorEntry: TimelineEntry {
    let date: Date
    let configured: Bool
    let sessionId: String?
    let title: String
    let status: String
    let lastMessage: String
    let lastRole: String
    let lastUpdated: Date?
    let error: String?
}

struct SessionMonitorProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SessionMonitorEntry {
        SessionMonitorEntry(date: Date(), configured: true, sessionId: "preview",
                            title: "My Session", status: "running",
                            lastMessage: "Working on the new feature…", lastRole: "assistant",
                            lastUpdated: Date(), error: nil)
    }

    func snapshot(for configuration: SessionMonitorIntent, in context: Context) async -> SessionMonitorEntry {
        await entry(for: configuration)
    }

    func timeline(for configuration: SessionMonitorIntent, in context: Context) async -> Timeline<SessionMonitorEntry> {
        let e = await entry(for: configuration)
        // Refresh every 15 minutes (WidgetKit budget-friendly).
        return Timeline(entries: [e], policy: .after(Date().addingTimeInterval(15 * 60)))
    }

    private func entry(for configuration: SessionMonitorIntent) async -> SessionMonitorEntry {
        let id = configuration.session?.id ?? WidgetAPI.extractSessionId(configuration.sessionIdManual)
        guard let creds = credentials(configuration), let id else {
            return SessionMonitorEntry(date: Date(), configured: false, sessionId: id,
                                       title: "", status: "", lastMessage: "", lastRole: "",
                                       lastUpdated: nil,
                                       error: id == nil ? "Pick a session" : "Enter server + login")
        }
        guard let detail = await WidgetAPI.fetchSessionDetail(creds, sessionId: id) else {
            return SessionMonitorEntry(date: Date(), configured: true, sessionId: id,
                                       title: "Session", status: "", lastMessage: "", lastRole: "",
                                       lastUpdated: nil, error: "Couldn't reach server")
        }
        return SessionMonitorEntry(
            date: Date(),
            configured: true,
            sessionId: id,
            title: WidgetAPI.title(detail.session),
            status: detail.session.status ?? "",
            lastMessage: detail.lastMessage?.content_preview ?? "",
            lastRole: detail.lastMessage?.role ?? "assistant",
            lastUpdated: WidgetDateParser.parse(detail.session.last_updated),
            error: nil
        )
    }

    private func credentials(_ c: SessionMonitorIntent) -> WidgetAPI.Credentials? {
        guard let url = c.serverURL, !url.isEmpty,
              let email = c.email, !email.isEmpty,
              let password = c.password, !password.isEmpty else { return nil }
        return WidgetAPI.Credentials(serverURL: url, email: email, password: password)
    }
}

enum WidgetDateParser {
    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return ISO8601DateFormatter().date(from: s)
    }
}

// MARK: - View

struct SessionMonitorWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SessionMonitorEntry

    private var statusColor: Color {
        switch entry.status {
        case "running": return .green
        case "awaiting_permission", "awaiting_input": return .orange
        case "failed": return .red
        default: return Color(white: 0.5)
        }
    }

    private var relativeTime: String {
        guard let d = entry.lastUpdated else { return "" }
        let diff = Date().timeIntervalSince(d)
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(Int(diff / 60))m ago" }
        if diff < 86400 { return "\(Int(diff / 3600))h ago" }
        return "\(Int(diff / 86400))d ago"
    }

    var body: some View {
        if !entry.configured || entry.sessionId == nil {
            VStack(spacing: 8) {
                Image(systemName: "gearshape").font(.largeTitle).foregroundStyle(.secondary)
                Text(entry.error ?? "Long-press → Edit to set up")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let chatURL = URL(string: "agor://session/\(entry.sessionId!)/chat")
            let voiceURL = URL(string: "agor://session/\(entry.sessionId!)/voice")
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(entry.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    if !relativeTime.isEmpty {
                        Text(relativeTime).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .padding(.bottom, 8)

                if let chatURL {
                    Link(destination: chatURL) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.lastRole == "user" ? "You:" : "Agent:")
                                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            Text(displayMessage)
                                .font(family == .systemLarge ? .callout : .caption)
                                .foregroundStyle(.primary)
                                .lineLimit(family == .systemLarge ? 10 : 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Spacer(minLength: 6)

                HStack {
                    if let e = entry.error {
                        Text(e).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                    }
                    Spacer()
                    if let voiceURL {
                        Link(destination: voiceURL) {
                            HStack(spacing: 5) {
                                Image(systemName: "mic.fill").font(.system(size: 13, weight: .semibold))
                                if family == .systemLarge { Text("Voice").font(.caption.weight(.semibold)) }
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, family == .systemLarge ? 14 : 0)
                            .frame(width: family == .systemLarge ? nil : 32, height: 32)
                            .background(Color.indigo, in: Capsule())
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private var displayMessage: String {
        if !entry.lastMessage.isEmpty { return entry.lastMessage }
        return "Tap to view messages"
    }
}

// MARK: - Widget

struct SessionMonitorWidget: Widget {
    let kind = "com.agor.SessionMonitor"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SessionMonitorIntent.self,
            provider: SessionMonitorProvider()
        ) { entry in
            SessionMonitorWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Session Monitor")
        .description("Latest message from a session + one-tap voice. Self-contained (enter your login).")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
