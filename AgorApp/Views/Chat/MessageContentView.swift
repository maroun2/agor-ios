import SwiftUI

struct MessageContentView: View {
    let blocks: [ContentBlock]
    var worktreeId: String?
    var socketService: SocketService?
    var knownSessionIds: Set<String> = []
    var knownFilePaths: [String] = []
    var knownSessionNames: [String: String] = [:]
    var onOpenFile: ((String) -> Void)?
    var onOpenSession: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block {
                case .text(let content):
                    EnhancedTextBlockView(
                        text: content.text,
                        worktreeId: worktreeId,
                        socketService: socketService,
                        knownSessionIds: knownSessionIds,
                        knownFilePaths: knownFilePaths,
                        knownSessionNames: knownSessionNames,
                        onOpenFile: onOpenFile,
                        onOpenSession: onOpenSession
                    )

                case .toolUse(let content):
                    ToolUseBlockView(content: content)

                case .toolResult(let content):
                    ToolResultBlockView(content: content)

                case .thinking(let content):
                    ThinkingBlockView(text: content.thinking)

                case .unknown:
                    EmptyView()
                }
            }
        }
    }
}
