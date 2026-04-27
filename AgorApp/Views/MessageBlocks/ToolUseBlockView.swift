import SwiftUI

struct ToolUseBlockView: View {
    let content: ToolUseContent

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)

                    Image(systemName: toolIcon)
                        .font(.caption)
                        .foregroundStyle(.blue)

                    Text(verbatim: content.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.blue)

                    Text(verbatim: content.inputSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(verbatim: formatJSON(content.input))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 6))
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
