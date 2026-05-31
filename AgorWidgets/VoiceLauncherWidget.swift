import WidgetKit
import SwiftUI

// MARK: - View

struct VoiceLauncherWidgetView: View {
    let entry: SessionTimelineEntry

    var body: some View {
        if let data = entry.sessionData,
           let url = URL(string: "agor://session/\(data.sessionId)/voice") {
            Link(destination: url) {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.35, green: 0.12, blue: 0.65),
                            Color(red: 0.12, green: 0.10, blue: 0.45)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    VStack(spacing: 6) {
                        Spacer()
                        Image(systemName: "mic.fill")
                            .font(.system(size: 40, weight: .medium))
                            .foregroundStyle(.white)
                        Spacer()
                        Text(data.sessionTitle)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 10)
                    }
                }
            }
        } else {
            ZStack {
                Color(red: 0.15, green: 0.10, blue: 0.30)
                VStack(spacing: 8) {
                    Image(systemName: "mic.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.35))
                    Text("No session")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
    }
}

// MARK: - Widget

struct VoiceLauncherWidget: Widget {
    let kind = "com.agor.VoiceLauncher"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SessionConfigurationIntent.self,
            provider: SessionTimelineProvider()
        ) { entry in
            VoiceLauncherWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Voice Launcher")
        .description("Tap to start voice mode for a session")
        .supportedFamilies([.systemSmall])
    }
}
