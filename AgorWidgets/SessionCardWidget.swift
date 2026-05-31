import WidgetKit
import SwiftUI

// MARK: - View

struct SessionCardWidgetView: View {
    let entry: SessionTimelineEntry

    private var statusColor: Color {
        switch entry.sessionData?.status {
        case "running": return .green
        case "awaiting_permission", "awaiting_input": return .orange
        default: return Color(white: 0.5)
        }
    }

    private var relativeTime: String {
        guard let data = entry.sessionData else { return "" }
        let diff = Date().timeIntervalSince(data.lastUpdated)
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(Int(diff / 60))m ago" }
        if diff < 86400 { return "\(Int(diff / 3600))h ago" }
        return "\(Int(diff / 86400))d ago"
    }

    var body: some View {
        if let data = entry.sessionData,
           let chatURL = URL(string: "agor://session/\(data.sessionId)/chat"),
           let voiceURL = URL(string: "agor://session/\(data.sessionId)/voice") {
            VStack(alignment: .leading, spacing: 0) {
                // Top: status dot + session name + agent icon
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(data.sessionTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "cpu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)

                // Middle: last message — taps to open chat
                Link(destination: chatURL) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(data.lastMessageRole == "user" ? "You:" : "Agent:")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(relativeTime)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(data.lastMessage.isEmpty ? "Tap to view messages" : data.lastMessage)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity)
                }

                Spacer(minLength: 6)

                // Bottom: mic button — taps to open voice
                HStack {
                    Spacer()
                    Link(destination: voiceURL) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Color.indigo)
                            .clipShape(Circle())
                    }
                }
            }
            .padding(12)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Long-press to select a session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Widget

struct SessionCardWidget: Widget {
    let kind = "com.agor.SessionCard"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SessionConfigurationIntent.self,
            provider: SessionTimelineProvider()
        ) { entry in
            SessionCardWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Session Card")
        .description("See last message and launch voice mode")
        .supportedFamilies([.systemMedium])
    }
}
