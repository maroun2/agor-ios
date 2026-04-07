import SwiftUI

struct EnhancedTextBlockView: View {
    let text: String
    let worktreeId: String?
    let socketService: SocketService?
    let knownSessionIds: Set<String>
    let onOpenFile: ((String) -> Void)?
    let onOpenSession: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Original markdown text
            TextBlockView(text: text)

            // File path links + inline images
            if let worktreeId, let socketService {
                let filePaths = FilePathDetector.detect(in: text)
                if !filePaths.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(filePaths, id: \.path) { detected in
                            VStack(alignment: .leading, spacing: 2) {
                                // File link
                                Button {
                                    onOpenFile?(detected.path)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: detected.isImage ? "photo" : "doc")
                                            .font(.caption2)
                                        Text(detected.path)
                                            .font(.caption)
                                            .lineLimit(1)
                                    }
                                    .foregroundStyle(.blue)
                                }

                                // Inline image preview
                                if detected.isImage {
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
                    .padding(.top, 2)
                }
            }

            // Session links
            let sessionLinks = SessionLinkDetector.detect(in: text, knownSessionIds: knownSessionIds)
            if !sessionLinks.isEmpty {
                HStack(spacing: 8) {
                    ForEach(sessionLinks, id: \.hash) { link in
                        Button {
                            onOpenSession?(link.hash)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.caption2)
                                Text(link.hash.prefix(8))
                                    .font(.caption.monospaced())
                            }
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}
