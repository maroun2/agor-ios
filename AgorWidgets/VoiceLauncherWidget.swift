import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Configuration

struct VoiceLaunchIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Voice Launcher"
    static var description = IntentDescription("One tap to start voice mode for a session. Paste the session ID (Session menu → Copy Session ID in the app).")

    @Parameter(title: "Session ID")
    var sessionId: String?
}

// MARK: - Timeline

struct VoiceLaunchEntry: TimelineEntry {
    let date: Date
    let sessionId: String?
}

struct VoiceLaunchProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> VoiceLaunchEntry {
        VoiceLaunchEntry(date: Date(), sessionId: "preview")
    }

    func snapshot(for configuration: VoiceLaunchIntent, in context: Context) async -> VoiceLaunchEntry {
        VoiceLaunchEntry(date: Date(), sessionId: WidgetAPI.extractSessionId(configuration.sessionId))
    }

    func timeline(for configuration: VoiceLaunchIntent, in context: Context) async -> Timeline<VoiceLaunchEntry> {
        // Static config — no refresh needed.
        Timeline(entries: [VoiceLaunchEntry(date: Date(), sessionId: WidgetAPI.extractSessionId(configuration.sessionId))], policy: .never)
    }
}

// MARK: - View

struct VoiceLauncherWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: VoiceLaunchEntry

    private var voiceURL: URL? {
        guard let id = entry.sessionId, !id.isEmpty else { return nil }
        return URL(string: "agor://session/\(id)/voice")
    }

    var body: some View {
        let configured = voiceURL != nil
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: configured ? "mic.fill" : "mic.slash")
                        .font(.system(size: 22, weight: .semibold))
                }
            default:
                ZStack {
                    LinearGradient(
                        colors: [Color(red: 0.35, green: 0.12, blue: 0.65), Color(red: 0.12, green: 0.10, blue: 0.45)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(systemName: configured ? "mic.fill" : "mic.slash")
                        .font(.system(size: 48, weight: .medium))
                        .foregroundStyle(.white.opacity(configured ? 1 : 0.4))
                }
            }
        }
        .widgetURL(voiceURL)
    }
}

// MARK: - Widget

struct VoiceLauncherWidget: Widget {
    let kind = "com.agor.VoiceLauncher"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: VoiceLaunchIntent.self,
            provider: VoiceLaunchProvider()
        ) { entry in
            VoiceLauncherWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Voice Launcher")
        .description("One tap to start voice mode for a session.")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}
