import SwiftUI

struct StreamingMessageView: View {
    let streaming: StreamingMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Role label
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Assistant")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                if streaming.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 6) {
                // Thinking indicator
                if streaming.isThinking || (streaming.thinkingContent != nil && !streaming.thinkingContent!.isEmpty) {
                    ThinkingIndicator(
                        isActive: streaming.isThinking,
                        content: streaming.thinkingContent
                    )
                }

                // Content — plain monospaced text while streaming
                if !streaming.content.isEmpty {
                    Text(streaming.content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }

                // Streaming cursor
                if streaming.isStreaming && !streaming.hasError {
                    PulsatingCursor()
                }

                // Error
                if streaming.hasError, let error = streaming.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Agent Working Indicator

struct AgentWorkingIndicator: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Assistant")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            HStack(spacing: 6) {
                DotPulse(delay: 0)
                DotPulse(delay: 0.2)
                DotPulse(delay: 0.4)
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DotPulse: View {
    let delay: Double
    @State private var scale: CGFloat = 0.6

    var body: some View {
        Circle()
            .fill(.secondary)
            .frame(width: 8, height: 8)
            .scaleEffect(scale)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 0.5)
                    .repeatForever(autoreverses: true)
                    .delay(delay)
                ) {
                    scale = 1.0
                }
            }
    }
}

// MARK: - Thinking Indicator

struct ThinkingIndicator: View {
    let isActive: Bool
    var content: String?

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let content, !content.isEmpty {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .italic()
            }
        } label: {
            HStack(spacing: 6) {
                if isActive {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(isActive ? "Thinking..." : "Thinking")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.purple)
            }
        }
        .onChange(of: isActive) { _, active in
            isExpanded = active
        }
    }
}

// MARK: - Pulsating Cursor

struct PulsatingCursor: View {
    @State private var isAnimating = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(.primary)
            .frame(width: 8, height: 16)
            .opacity(isAnimating ? 1 : 0.3)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    isAnimating = true
                }
            }
    }
}
