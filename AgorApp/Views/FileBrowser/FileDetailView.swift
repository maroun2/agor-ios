import SwiftUI

struct FileDetailView: View {
    let viewModel: FileBrowserViewModel
    let filePath: String

    @State private var imageScale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var imageOffset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    /// Decoded off the main thread; nil while loading or on failure.
    @State private var decodedImage: UIImage?

    var body: some View {
        Group {
            if viewModel.isLoadingFile {
                ProgressView("Loading file...")
            } else if let detail = viewModel.fileDetail, detail.path == filePath {
                if detail.encoding == "base64", isImageFile(filePath) {
                    // Zoomable image (no ScrollView - gestures need direct access)
                    zoomableImage(uiImage: decodedImage)
                } else {
                    ScrollView {
                        if let content = detail.content {
                            Text(content)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        } else {
                            Text("No content available")
                                .foregroundStyle(.secondary)
                                .padding()
                        }
                    }
                }
            } else if let error = viewModel.error {
                ContentUnavailableView {
                    Label("Error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else {
                Color.clear
            }
        }
        .navigationTitle(filePath.components(separatedBy: "/").last ?? filePath)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.loadFileDetail(filePath)
            await decodeCurrentImage()
        }
        .onChange(of: filePath) { _, _ in
            decodedImage = nil
            imageScale = 1.0
            lastScale = 1.0
            imageOffset = .zero
            lastOffset = .zero
            Task { await decodeCurrentImage() }
        }
    }

    private func decodeCurrentImage() async {
        guard let detail = viewModel.fileDetail,
              detail.path == filePath,
              detail.encoding == "base64",
              isImageFile(filePath),
              let content = detail.content,
              let data = Data(base64Encoded: content) else { return }
        let image = await Task.detached(priority: .userInitiated) { decodeGIF(data) }.value
        decodedImage = image
    }

    @ViewBuilder
    private func zoomableImage(uiImage: UIImage?) -> some View {
        if let uiImage {
            if uiImage.images != nil {
                // Animated GIF — UIViewRepresentable drives the animation loop
                AnimatedImageView(image: uiImage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(imageScale)
                    .offset(imageOffset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                imageScale = lastScale * value
                            }
                            .onEnded { value in
                                imageScale = max(1.0, min(lastScale * value, 5.0))
                                lastScale = imageScale
                                if imageScale == 1.0 {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        imageOffset = .zero
                                    }
                                    lastOffset = .zero
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                guard imageScale > 1.0 else { return }
                                imageOffset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                lastOffset = imageOffset
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            if imageScale > 1.0 {
                                imageScale = 1.0
                                lastScale = 1.0
                                imageOffset = .zero
                                lastOffset = .zero
                            } else {
                                imageScale = 3.0
                                lastScale = 3.0
                            }
                        }
                    }
            }
        } else {
            // Still decoding — show spinner while Task.detached runs
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func isImageFile(_ path: String) -> Bool {
        let ext = path.components(separatedBy: ".").last?.lowercased() ?? ""
        return ["png", "jpg", "jpeg", "gif", "svg", "webp", "ico"].contains(ext)
    }
}
