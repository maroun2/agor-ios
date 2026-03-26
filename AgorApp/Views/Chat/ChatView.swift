import SwiftUI

struct ChatView: View {
    let viewModel: ChatViewModel
    let sessionId: String

    @State private var scrollProxy: ScrollViewProxy?

    var body: some View {
        VStack(spacing: 0) {
            // Connection lost banner
            if viewModel.error != nil {
                ConnectionLostBanner(
                    error: viewModel.error!,
                    onRetry: {
                        viewModel.error = nil
                        Task { await viewModel.loadMessages(sessionId) }
                    }
                )
            }

            // Attention bar
            if viewModel.sessionNeedsAttention {
                AttentionBar(viewModel: viewModel, scrollProxy: scrollProxy)
            }

            // Plan mode indicator
            if viewModel.currentSession?.isPlanMode == true {
                PlanModeBar()
            }

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Load more
                        if viewModel.hasMore {
                            Button("Load earlier messages") {
                                Task { await viewModel.loadMore() }
                            }
                            .font(.caption)
                            .padding()
                        }

                        ForEach(viewModel.displayItems) { item in
                            switch item {
                            case .taskHeader(let task):
                                TaskHeader(
                                    task: task,
                                    isCollapsed: viewModel.collapsedTaskIds.contains(task.taskId),
                                    onToggle: { viewModel.toggleTaskCollapsed(task.taskId) }
                                )
                                .id(item.id)

                            case .message(let message):
                                MessageBubble(
                                    message: message,
                                    viewModel: viewModel
                                )
                                .id(item.id)

                            case .streaming(let streaming):
                                StreamingMessageView(streaming: streaming)
                                    .id(item.id)
                            }
                        }

                        // Bottom anchor
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.vertical, 8)
                }
                .refreshable {
                    viewModel.error = nil
                    viewModel.resetMessagePagination()
                    await viewModel.loadMessages(sessionId)
                }
                .onAppear { scrollProxy = proxy }
                .onChange(of: viewModel.scrollToBottomToken) { _, _ in
                    DispatchQueue.main.async {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            // Prompt input
            PromptInputBar(viewModel: viewModel)
        }
        .navigationTitle(viewModel.currentSession?.displayTitle ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let session = viewModel.currentSession {
                    HStack(spacing: 8) {
                        if session.isPlanMode {
                            PlanModeBadge()
                        }
                        StatusBadge(status: session.status)
                        AgentIcon(agenticTool: session.agenticTool, size: 18)
                    }
                }
            }
        }
        .overlay {
            if viewModel.isLoadingMessages && viewModel.messages.isEmpty {
                ProgressView("Loading messages...")
            } else if viewModel.messages.isEmpty && viewModel.activeStreams.isEmpty && !viewModel.isLoadingMessages && viewModel.error == nil {
                ContentUnavailableView(
                    "No Messages",
                    systemImage: "bubble.left",
                    description: Text("Send a prompt to get started")
                )
            }
        }
    }
}

// MARK: - Attention Bar

private struct AttentionBar: View {
    let viewModel: ChatViewModel
    let scrollProxy: ScrollViewProxy?

    var body: some View {
        Button {
            let targetId = viewModel.firstPendingPermissionId ?? viewModel.firstPendingInputId
            if let targetId {
                withAnimation {
                    scrollProxy?.scrollTo("msg-\(targetId)", anchor: .center)
                }
            }
        } label: {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Needs attention")
                    .font(.caption.weight(.medium))
                Image(systemName: "arrow.down")
                    .font(.caption2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Plan Mode Bar

private struct PlanModeBar: View {
    var body: some View {
        HStack {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.purple)
            Text("Plan Mode — read-only, no tool execution")
                .font(.caption)
                .foregroundStyle(.purple)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(.purple.opacity(0.08))
    }
}

// MARK: - Plan Mode Badge

struct PlanModeBadge: View {
    var body: some View {
        Text("Plan")
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.purple.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.purple)
    }
}

// MARK: - Connection Lost Banner

private struct ConnectionLostBanner: View {
    let error: String
    let onRetry: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.red)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Retry", action: onRetry)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.red.opacity(0.08))
    }
}
