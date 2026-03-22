import SwiftUI

struct ToolUseBlockView: View {
    let content: ToolUseContent

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            // Full input JSON
            ScrollView(.horizontal, showsIndicators: false) {
                Text(formatJSON(content.input))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: toolIcon)
                    .font(.caption)
                    .foregroundStyle(.blue)

                Text(content.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.blue)

                Text(content.inputSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var toolIcon: String {
        switch content.name.lowercased() {
        case "bash", "bash_cmd": "terminal"
        case "edit": "pencil"
        case "write": "doc.text"
        case "read": "eye"
        case "glob", "grep": "magnifyingglass"
        case "agent": "person.2"
        default: "wrench"
        }
    }

    private func formatJSON(_ dict: [String: AnyCodable]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict.mapValues(\.value),
            options: [.prettyPrinted, .sortedKeys]
        ) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
