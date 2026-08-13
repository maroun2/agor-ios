import SwiftUI

struct InlineImageView: View {
    let path: String
    let worktreeId: String
    let socketService: SocketService
    let onTapFile: (String) -> Void

    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var failed = false
    @State private var retriesLeft = 1

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
                ProgressView()
                    .frame(width: 100, height: 60)
            } else if failed {
                Label("Image unavailable", systemImage: "photo.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await loadImage() }
    }

    @MainActor
    private func loadImage() async {
        guard image == nil, !isLoading, !failed else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            // Thumbnails come from the same 3-day disk cache as the file browser,
            // so a scrolled-past image doesn't refetch on every appearance. Misses
            // go through the shared loader, which runs one download at a time.
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
            // One retry: a transient socket timeout shouldn't leave a permanent
            // "Image unavailable" placeholder for the life of the view.
            if !Task.isCancelled, retriesLeft > 0 {
                retriesLeft -= 1
                try? await Task.sleep(for: .seconds(1))
                isLoading = false
                await loadImage()
                return
            }
            failed = true
        }
    }
}
