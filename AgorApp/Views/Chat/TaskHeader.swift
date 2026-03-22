import SwiftUI

struct TaskHeader: View {
    let task: AgorTask

    @State private var isCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.horizontal)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCollapsed.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Image(systemName: "bubble.left.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)

                    Text(task.promptPreview)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer()

                    TaskStatusBadge(status: task.status)

                    if let duration = task.formattedDuration {
                        Text(duration)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        }
    }
}
