import SwiftUI

struct ThinkingBlockView: View {
    let text: String?

    @State private var isExpanded = false

    var body: some View {
        if let text, !text.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                Text(verbatim: text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .italic()
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } label: {
                thinkingLabel
            }
        } else {
            thinkingLabel
                .foregroundStyle(.tertiary)
        }
    }

    private var thinkingLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "brain")
                .font(.caption)
                .foregroundStyle(.purple.opacity(text == nil ? 0.4 : 1))
            Text(text == nil ? "Thinking (redacted)" : "Thinking")
                .font(.caption.weight(.medium))
                .foregroundStyle(.purple.opacity(text == nil ? 0.4 : 1))
        }
    }
}
