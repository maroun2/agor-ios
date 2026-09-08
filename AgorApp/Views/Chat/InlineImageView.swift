import SwiftUI

struct InlineImageView: View {
    let path: String
    let worktreeId: String
    let socketService: SocketService
    let onTapFile: (String) -> Void

    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var failed = false

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private var progressKey: String {
        InlineImageLoader.progressKey(baseURL: socketService.httpClient.baseURL, worktreeId: worktreeId, path: path)
    }

    private var progress: InlineImageLoader.Progress? {
        InlineImageLoader.shared.progress[progressKey]
    }

    var body: some View {
        ZStack {
            if let image {
                Group {
                    if image.images != nil {
                        AnimatedImageView(image: image)
                    } else {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                }
                .frame(maxWidth: 280, maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onTapGesture { onTapFile(path) }
            } else if isLoading {
                placeholder
            } else if failed {
                // Retries already happened inside the loader with backoff —
                // a permanent failure needs a visible, tappable way out rather
                // than a dead "Image unavailable" label the user can't act on.
                Button {
                    failed = false
                    Task { await loadImage() }
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .frame(width: 100, height: 60)
            }
        }
        .task { await loadImage() }
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 4) {
            switch progress?.phase {
            case .scanning:
                ProgressView()
                Text("Scanning files…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            case .downloading:
                if let total = progress?.expectedTotalBytes, total > 0 {
                    ProgressView(value: Double(progress?.bytesReceived ?? 0), total: Double(total))
                        .frame(width: 80)
                    Text("\(Self.byteFormatter.string(fromByteCount: Int64(progress?.bytesReceived ?? 0))) / \(Self.byteFormatter.string(fromByteCount: Int64(total)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            case nil:
                ProgressView()
            }
        }
        .frame(width: 100, height: 60)
    }

    @MainActor
    private func loadImage() async {
        guard image == nil, !isLoading, !failed else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            // Thumbnails come from the same 3-day disk cache as the file browser,
            // so a scrolled-past image doesn't refetch on every appearance. Misses
            // go through the shared loader, which runs one download at a time and
            // retries transient failures itself.
            let detail = try await InlineImageLoader.shared.load(
                path: path,
                worktreeId: worktreeId,
                socketService: socketService
            )

            guard let content = detail.content else { failed = true; return }

            // Allow up to 5MB base64 (~3.75MB actual image data)
            guard content.utf8.count < 5_000_000 else { failed = true; return }

            if detail.encoding == "base64",
               let data = Data(base64Encoded: content),
               let uiImage = decodeGIF(data) {
                self.image = uiImage
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }
}
