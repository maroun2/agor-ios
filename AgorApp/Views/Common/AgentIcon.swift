import SwiftUI

struct AgentIcon: View {
    let agenticTool: AgenticToolName
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: iconName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(iconColor)
    }

    private var iconName: String {
        switch agenticTool {
        case .claudeCode: "star.fill"
        case .codex: "cube"
        case .gemini: "diamond"
        case .opencode: "chevron.left.forwardslash.chevron.right"
        }
    }

    private var iconColor: Color {
        switch agenticTool {
        case .claudeCode: .orange
        case .codex: .green
        case .gemini: .blue
        case .opencode: .purple
        }
    }
}
