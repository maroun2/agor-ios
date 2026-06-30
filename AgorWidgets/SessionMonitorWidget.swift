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
    let pageText: String
    let pageIndex: Int
    let pageCount: Int
    let lastRole: String
    let lastUpdated: Date?
    let error: String?
}

struct SessionMonitorProvider: AppIntentTimelineProvider {
    /// How long each page of a long message stays on screen before rotating.
    private let pageInterval: TimeInterval = 30
    /// Roughly how long one full timeline of rotation lasts before re-fetching.
    private let rotationWindow: TimeInterval = 10 * 60

    func placeholder(in context: Context) -> SessionMonitorEntry {
        SessionMonitorEntry(date: Date(), configured: true, sessionId: "preview",
                            title: "My Session", status: "running",
                            pageText: "Working on the new feature implementation…",
                            pageIndex: 0, pageCount: 1, lastRole: "assistant",
                            lastUpdated: Date(), error: nil)
    }

    func snapshot(for configuration: SessionMonitorIntent, in context: Context) async -> SessionMonitorEntry {
        let base = await fetchBase(configuration)
        let pages = paginate(base.fullText, family: context.family)
        return makeEntry(base, page: pages.first ?? "", index: 0, count: pages.count, date: Date())
    }

    func timeline(for configuration: SessionMonitorIntent, in context: Context) async -> Timeline<SessionMonitorEntry> {
        let base = await fetchBase(configuration)
        let now = Date()

        guard base.configured, base.sessionId != nil, base.error == nil else {
            // Not set up / unreachable — single entry, retry in 5 min.
            let e = makeEntry(base, page: base.fullText, index: 0, count: 1, date: now)
            return Timeline(entries: [e], policy: .after(now.addingTimeInterval(5 * 60)))
        }

        let pages = paginate(base.fullText, family: context.family)

        if pages.count <= 1 {
            // Short message — no rotation needed; refresh every 15 min.
            let e = makeEntry(base, page: pages.first ?? "", index: 0, count: 1, date: now)
            return Timeline(entries: [e], policy: .after(now.addingTimeInterval(15 * 60)))
        }

        // Long message — emit one entry per page, rotating, looping to fill the window.
        let totalSlots = max(pages.count, Int(rotationWindow / pageInterval))
        var entries: [SessionMonitorEntry] = []
        for slot in 0..<totalSlots {
            let idx = slot % pages.count
            let date = now.addingTimeInterval(Double(slot) * pageInterval)
            entries.append(makeEntry(base, page: pages[idx], index: idx, count: pages.count, date: date))
        }
        // .atEnd re-runs the provider (re-fetches the latest message) when rotation finishes.
        return Timeline(entries: entries, policy: .atEnd)
    }

    // MARK: Fetch

    private struct Base {
        var configured: Bool
        var sessionId: String?
        var title: String
        var status: String
        var fullText: String
        var lastRole: String
        var lastUpdated: Date?
        var error: String?
    }

    private func fetchBase(_ c: SessionMonitorIntent) async -> Base {
        let id = c.session?.id ?? WidgetAPI.extractSessionId(c.sessionIdManual)
        guard let creds = credentials(c), let id else {
            return Base(configured: false, sessionId: id, title: "", status: "",
                        fullText: "", lastRole: "", lastUpdated: nil,
                        error: id == nil ? "Pick a session" : "Enter server + login")
        }
        guard let detail = await WidgetAPI.fetchSessionDetail(creds, sessionId: id) else {
            return Base(configured: true, sessionId: id, title: "Session", status: "",
                        fullText: "", lastRole: "", lastUpdated: nil, error: "Couldn't reach server")
        }
        return Base(
            configured: true,
            sessionId: id,
            title: WidgetAPI.title(detail.session),
            status: detail.session.status ?? "",
            fullText: detail.lastMessage?.fullText ?? "",
            lastRole: detail.lastMessage?.role ?? "assistant",
            lastUpdated: WidgetDateParser.parse(detail.session.last_updated),
            error: nil
        )
    }

    private func makeEntry(_ b: Base, page: String, index: Int, count: Int, date: Date) -> SessionMonitorEntry {
        SessionMonitorEntry(date: date, configured: b.configured, sessionId: b.sessionId,
                            title: b.title, status: b.status, pageText: page,
                            pageIndex: index, pageCount: count, lastRole: b.lastRole,
                            lastUpdated: b.lastUpdated, error: b.error)
    }

    private func credentials(_ c: SessionMonitorIntent) -> WidgetAPI.Credentials? {
        guard let url = c.serverURL, !url.isEmpty,
              let email = c.email, !email.isEmpty,
              let password = c.password, !password.isEmpty else { return nil }
        return WidgetAPI.Credentials(serverURL: url, email: email, password: password)
    }

    /// Split text into word-boundary pages sized for the widget family.
    private func paginate(_ text: String, family: WidgetFamily) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pageSize = family == .systemLarge ? 700 : 230
        guard trimmed.count > pageSize else { return trimmed.isEmpty ? [] : [trimmed] }

        var pages: [String] = []
        var current = ""
        for word in trimmed.split(separator: " ", omittingEmptySubsequences: false) {
            if current.count + word.count + 1 > pageSize, !current.isEmpty {
                pages.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            }
            current += word + " "
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { pages.append(tail) }
        return pages.isEmpty ? [trimmed] : pages
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
        if diff < 60 { return "now" }
        if diff < 3600 { return "\(Int(diff / 60))m" }
        if diff < 86400 { return "\(Int(diff / 3600))h" }
        return "\(Int(diff / 86400))d"
    }

    private var messageFontSize: CGFloat { family == .systemLarge ? 13 : 11 }

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
            VStack(alignment: .leading, spacing: 5) {
                // Header: status + title + page indicator
                HStack(spacing: 5) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(entry.title).font(.caption.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if entry.pageCount > 1 {
                        Text("\(entry.pageIndex + 1)/\(entry.pageCount)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.secondary.opacity(0.15), in: Capsule())
                    }
                }

                // Message page — fills available space, tap → chat
                if let chatURL {
                    Link(destination: chatURL) {
                        Text(displayMessage)
                            .font(.system(size: messageFontSize))
                            .foregroundStyle(.primary)
                            .lineLimit(family == .systemLarge ? 18 : 4)
                            .minimumScaleFactor(0.7)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }

                // Footer: role + time + voice
                HStack(spacing: 6) {
                    Text(entry.lastRole == "user" ? "You" : "Agent")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    if !relativeTime.isEmpty {
                        Text("· \(relativeTime)").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    if let e = entry.error {
                        Text("· \(e)").font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1)
                    }
                    Spacer()
                    if let voiceURL {
                        Link(destination: voiceURL) {
                            HStack(spacing: 4) {
                                Image(systemName: "mic.fill").font(.system(size: 11, weight: .semibold))
                                Text("Voice").font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.indigo, in: Capsule())
                        }
                    }
                }
            }
            .padding(11)
        }
    }

    private var displayMessage: String {
        entry.pageText.isEmpty ? "Tap to view messages" : entry.pageText
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
        .description("Latest message from a session (auto-scrolls long replies) + one-tap voice.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
