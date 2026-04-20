import SwiftUI

struct InlineImageView: View {
    let path: String
    let worktreeId: String
    let socketService: SocketService
    let onTapFile: (String) -> Void

    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
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

    private func loadImage() async {
        guard image == nil, !isLoading, !failed else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let detail: FileDetail = try await socketService.serviceGet(
                service: "file",
                id: path,
                query: ["worktree_id": worktreeId]
            )

            guard let content = detail.content else { failed = true; return }

            // Allow up to 5MB base64 (~3.75MB actual image data)
            guard content.utf8.count < 5_000_000 else { failed = true; return }

            if detail.encoding == "base64",
               let data = Data(base64Encoded: content),
               let uiImage = UIImage(data: data) {
                self.image = uiImage
            } else {
                failed = true
            }
        } catch {
            failed = true
        }
    }
}
