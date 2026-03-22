import SwiftUI

struct ToolResultBlockView: View {
    let content: ToolResultContent

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let resultContent = content.content {
                ScrollView {
                    Text(resultContent.textPreview)
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
        } label: {
            HStack(spacing: 6) {
                Image(systemName: content.isError == true ? "xmark.circle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(content.isError == true ? .red : .green)

                Text("Result")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                if let preview = content.content?.textPreview {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}
