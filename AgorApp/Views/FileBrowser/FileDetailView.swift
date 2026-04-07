import SwiftUI

struct FileDetailView: View {
    let viewModel: FileBrowserViewModel
    let filePath: String

    @State private var imageScale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var imageOffset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        Group {
            if viewModel.isLoadingFile {
                ProgressView("Loading file...")
            } else if let detail = viewModel.fileDetail, detail.path == filePath {
                if detail.encoding == "base64", isImageFile(filePath) {
                    // Zoomable image (no ScrollView - gestures need direct access)
                    zoomableImage(detail: detail)
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
        }
        .onChange(of: filePath) { _, _ in
            imageScale = 1.0
            lastScale = 1.0
            imageOffset = .zero
            lastOffset = .zero
        }
    }

    @ViewBuilder
    private func zoomableImage(detail: FileDetail) -> some View {
        if let content = detail.content,
           let data = Data(base64Encoded: content),
           let uiImage = UIImage(data: data) {
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
        } else {
            Text("Unable to display image")
                .foregroundStyle(.secondary)
        }
    }

    private func isImageFile(_ path: String) -> Bool {
        let ext = path.components(separatedBy: ".").last?.lowercased() ?? ""
        return ["png", "jpg", "jpeg", "gif", "svg", "webp", "ico"].contains(ext)
    }
}
