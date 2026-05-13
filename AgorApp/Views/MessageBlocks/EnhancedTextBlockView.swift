import SwiftUI

struct EnhancedTextBlockView: View {
    let text: String
    let worktreeId: String?
    let socketService: SocketService?
    let knownSessionIds: Set<String>
    var knownFilePaths: [String] = []
    var knownSessionNames: [String: String] = [:]
    let onOpenFile: ((String) -> Void)?
    let onOpenSession: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Markdown text with inline tappable links for files and sessions
            let filePaths = (worktreeId != nil && socketService != nil)
                ? FilePathDetector.detect(in: text, knownFiles: knownFilePaths)
                : []
            let sessionLinks = SessionLinkDetector.detect(in: text, knownSessionIds: knownSessionIds)

            if filePaths.isEmpty && sessionLinks.isEmpty {
                TextBlockView(text: text)
            } else {
                InlineLinkedTextView(
                    text: text,
                    filePaths: filePaths,
                    sessionLinks: sessionLinks,
                    knownSessionNames: knownSessionNames,
                    onOpenFile: onOpenFile,
                    onOpenSession: onOpenSession
                )
            }

            // Inline image previews (below text, for detected image paths)
            if let worktreeId, let socketService {
                let imagePaths = filePaths.filter(\.isImage)
                if !imagePaths.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(imagePaths, id: \.path) { detected in
                            InlineImageView(
                                path: detected.path,
                                worktreeId: worktreeId,
                                socketService: socketService,
                                onTapFile: { path in onOpenFile?(path) }
                            )
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Inline Linked Text

/// Renders markdown text with file paths and session links as tappable inline elements.
private struct InlineLinkedTextView: View {
    let text: String
    let filePaths: [DetectedFilePath]
    let sessionLinks: [DetectedSessionLink]
    let knownSessionNames: [String: String]
    let onOpenFile: ((String) -> Void)?
    let onOpenSession: ((String) -> Void)?

    var body: some View {
        // Use a FlowLayout of Text + Buttons interleaved
        // Since SwiftUI Text concatenation doesn't support tap handlers on segments,
        // render markdown normally and add small inline link chips for detected paths
        VStack(alignment: .leading, spacing: 4) {
            TextBlockView(text: text)

            // Compact inline link chips
            let allLinks = buildLinkChips()
            if !allLinks.isEmpty {
                WrappingHStack(alignment: .leading, spacing: 4) {
                    ForEach(allLinks) { chip in
                        Button {
                            chip.action()
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: chip.icon)
                                    .font(.system(size: 9))
                                Text(chip.label)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(chip.color)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(chip.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }
        }
    }

    private func buildSegments() -> [TextSegment] {
        // Kept for a potential future inline text rendering approach.
        []
    }

    private func buildLinkChips() -> [LinkChip] {
        var chips: [LinkChip] = []

        for detected in filePaths {
            let fileName = detected.path.components(separatedBy: "/").last ?? detected.path
            chips.append(LinkChip(
                id: "file-\(detected.path)",
                icon: detected.isImage ? "photo" : "doc.text",
                label: fileName,
                color: .blue,
                action: { onOpenFile?(detected.path) }
            ))
        }

        for link in sessionLinks {
            // Resolve session name: try exact match, then prefix match
            let resolvedName = knownSessionNames[link.hash]
                ?? knownSessionNames.first(where: { $0.key.hasPrefix(link.hash) })?.value
            let label: String
            if let resolvedName {
                label = resolvedName
            } else if let slug = link.boardSlug {
                label = "\(slug) · \(link.hash.prefix(8))"
            } else {
                label = String(link.hash.prefix(8))
            }
            let icon = link.boardSlug != nil ? "link" : "bubble.left.and.bubble.right"
            chips.append(LinkChip(
                id: "session-\(link.hash)",
                icon: icon,
                label: label,
                color: .purple,
                action: { onOpenSession?(link.hash) }
            ))
        }

        return chips
    }
}

private struct TextSegment {
    enum Kind { case text, filePath, sessionLink }
    let kind: Kind
    let content: String
    let path: String? // resolved path for files, hash for sessions
}

private struct LinkChip: Identifiable {
    let id: String
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void
}

// MARK: - Wrapping HStack (flow layout)

private struct WrappingHStack: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            guard index < result.positions.count else { break }
            let pos = result.positions[index]
            subview.place(at: CGPoint(x: bounds.minX + pos.x, y: bounds.minY + pos.y), proposal: .unspecified)
        }
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return LayoutResult(
            size: CGSize(width: maxWidth, height: y + rowHeight),
            positions: positions
        )
    }

    private struct LayoutResult {
        let size: CGSize
        let positions: [CGPoint]
    }
}
