import SwiftUI

struct ImageBlockView: View {
    let content: ImageContent

    @State private var isExpanded = false

    var body: some View {
        Group {
            if let uiImage = content.source.uiImage {
                // Base64 inline image
                inlineImage(Image(uiImage: uiImage))
            } else if let url = content.source.remoteURL {
                // Remote URL image
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        inlineImage(image)
                    case .failure:
                        Label("Image failed to load", systemImage: "photo.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .empty:
                        ProgressView()
                            .frame(height: 80)
                    @unknown default:
                        EmptyView()
                    }
                }
            } else {
                Label("Image", systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func inlineImage(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .frame(maxWidth: isExpanded ? .infinity : 240, maxHeight: isExpanded ? .infinity : 180)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { withAnimation { isExpanded.toggle() } }
    }
}
