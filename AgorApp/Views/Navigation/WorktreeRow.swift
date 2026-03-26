import SwiftUI

struct WorktreeRow: View {
    let worktree: Worktree
    var repoName: String?
    var attentionCount: Int = 0

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
                .font(.caption)

            VStack(alignment: .leading, spacing: 2) {
                Text(worktree.displayName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                // Project name · branch ref
                HStack(spacing: 4) {
                    if let repoName {
                        Text(repoName)
                            .lineLimit(1)
                        Text("·")
                            .foregroundStyle(.tertiary)
                    }
                    Text(worktree.ref)
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if attentionCount > 0 {
                Text("\(attentionCount)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange, in: Capsule())
            }
        }
    }
}
