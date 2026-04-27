import SwiftUI

struct ToolResultBlockView: View {
    let content: ToolResultContent

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

                    Image(systemName: content.isError == true ? "xmark.circle" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(content.isError == true ? .red : .green)

                    Text("Result")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    if let preview = content.content?.textPreview {
                        Text(verbatim: preview)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if let resultContent = content.content {
                    ScrollView {
                        Text(verbatim: resultContent.textPreview)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 200)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}
