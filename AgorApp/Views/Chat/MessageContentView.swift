import SwiftUI

struct MessageContentView: View {
    let blocks: [ContentBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block {
                case .text(let content):
                    TextBlockView(text: content.text)

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
