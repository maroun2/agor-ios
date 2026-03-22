import SwiftUI

struct SessionRow: View {
    let session: Session
    var showAttentionBadge: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            AgentIcon(agenticTool: session.agenticTool, size: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(.subheadline)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    StatusBadge(status: session.status)

                    if session.isPlanMode {
                        Text("Plan")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.purple.opacity(0.2), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.purple)
                    }

                    Text(session.lastUpdated.relativeTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if showAttentionBadge && session.status.needsAttention {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}
