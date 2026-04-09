import SwiftUI

struct MessageBubble: View {
    let message: Message
    let viewModel: ChatViewModel
    var worktreeId: String?
    var socketService: SocketService?
    var knownSessionIds: Set<String> = []
    var knownFilePaths: [String] = []
    var knownSessionNames: [String: String] = [:]
    var onOpenFile: ((String) -> Void)?
    var onOpenSession: ((String) -> Void)?

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            // Role label
            if message.role != .system {
                HStack(spacing: 4) {
                    if message.role == .assistant {
                        Image(systemName: "cpu")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(roleLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(message.timestamp.shortTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
            }

            // Content
            Group {
                switch message.content {
                case .text(let text):
                    EnhancedTextBlockView(
                        text: text,
                        worktreeId: worktreeId,
                        socketService: socketService,
                        knownSessionIds: knownSessionIds,
                        knownFilePaths: knownFilePaths,
                        knownSessionNames: knownSessionNames,
                        onOpenFile: onOpenFile,
                        onOpenSession: onOpenSession
                    )

                case .blocks(let blocks):
                    MessageContentView(
                        blocks: blocks,
                        worktreeId: worktreeId,
                        socketService: socketService,
                        knownSessionIds: knownSessionIds,
                        knownFilePaths: knownFilePaths,
                        knownSessionNames: knownSessionNames,
                        onOpenFile: onOpenFile,
                        onOpenSession: onOpenSession
                    )

                case .permissionRequest(let perm):
                    PermissionCardView(
                        content: perm,
                        isFirstPending: message.messageId == viewModel.firstPendingPermissionId,
                        onApprove: { scope in
                            viewModel.approvePermission(
                                requestId: perm.requestId,
                                taskId: perm.taskId ?? message.taskId,
                                scope: scope
                            )
                        },
                        onDeny: {
                            viewModel.denyPermission(
                                requestId: perm.requestId,
                                taskId: perm.taskId ?? message.taskId
                            )
                        }
                    )

                case .inputRequest(let input):
                    InputRequestCardView(
                        content: input,
                        isFirstPending: message.messageId == viewModel.firstPendingInputId,
                        onSubmit: { answers in
                            viewModel.submitInput(
                                requestId: input.requestId,
                                taskId: input.taskId ?? message.taskId,
                                answers: answers
                            )
                        }
                    )
                }
            }
            .padding(bubblePadding)
            .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: maxWidth, alignment: alignment == .leading ? .leading : .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private var roleLabel: String {
        switch message.role {
        case .user: "You"
        case .assistant: "Assistant"
        case .system: "System"
        }
    }

    private var alignment: HorizontalAlignment {
        message.role == .user ? .trailing : .leading
    }

    private var frameAlignment: Alignment {
        message.role == .user ? .trailing : .leading
    }

    private var maxWidth: CGFloat {
        message.role == .user ? 300 : .infinity
    }

    private var bubblePadding: EdgeInsets {
        EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    }

    private var bubbleBackground: some ShapeStyle {
        switch message.role {
        case .user:
            return AnyShapeStyle(.tint.opacity(0.15))
        case .assistant:
            return AnyShapeStyle(.secondary.opacity(0.1))
        case .system:
            return AnyShapeStyle(.tertiary.opacity(0.1))
        }
    }
}
