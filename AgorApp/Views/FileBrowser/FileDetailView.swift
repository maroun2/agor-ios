import SwiftUI

struct FileDetailView: View {
    let viewModel: FileBrowserViewModel
    let filePath: String

    var body: some View {
        Group {
            if viewModel.isLoadingFile {
                ProgressView("Loading file...")
            } else if let detail = viewModel.fileDetail, detail.path == filePath {
                ScrollView {
                    if detail.encoding == "base64", isImageFile(filePath) {
                        // Image display
                        if let data = Data(base64Encoded: detail.content),
                           let uiImage = UIImage(data: data) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .padding()
                        } else {
                            Text("Unable to display image")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        // Text display
                        Text(detail.content)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
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
    }

    private func isImageFile(_ path: String) -> Bool {
        let ext = path.components(separatedBy: ".").last?.lowercased() ?? ""
        return ["png", "jpg", "jpeg", "gif", "svg", "webp", "ico"].contains(ext)
    }
}
