import SwiftUI
import PDFKit

struct FileDetailView: View {
    let viewModel: FileBrowserViewModel
    let filePath: String

    @State private var imageScale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var imageOffset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    /// Decoded off the main thread; nil while loading or on failure.
    @State private var decodedImage: UIImage?
    /// Temp-file copy of the current file, for the share / open-in-app flow.
    @State private var exportedFileURL: URL?
    @State private var showShareSheet = false
    /// Extensions the user chose to always hand to an external app.
    @AppStorage("agor.openExternallyExtensions") private var openExternallyRaw = ""

    var body: some View {
        Group {
            if viewModel.isLoadingFile {
                ProgressView("Loading file...")
            } else if let detail = viewModel.fileDetail, isCurrentFile(detail) {
                if detail.encoding == "base64", isPDFFile(filePath) {
                    pdfPreview(detail: detail)
                } else if detail.encoding == "base64", isImageFile(filePath) {
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        prepareExportAndShare()
                    } label: {
                        Label("Open in app…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!(viewModel.fileDetail.map(isCurrentFile) ?? false))

                    Button {
                        Task {
                            // The decoded image is view state, not part of
                            // fileDetail — without clearing and re-decoding it the
                            // refetched file only appeared after leaving and
                            // reopening the view.
                            decodedImage = nil
                            await viewModel.redownloadFile(filePath)
                            await decodeCurrentImage()
                        }
                    } label: {
                        Label("Clear cache & redownload", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isLoadingFile)

                    Toggle(isOn: openExternallyBinding) {
                        Label("Always open .\(fileExtension) externally", systemImage: "arrow.up.forward.app")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let exportedFileURL {
                ActivityShareSheet(items: [exportedFileURL])
            }
        }
        .task {
            await viewModel.loadFileDetail(filePath)
            await decodeCurrentImage()
            autoOpenExternallyIfConfigured()
        }
        .onChange(of: filePath) { _, _ in
            decodedImage = nil
            exportedFileURL = nil
            imageScale = 1.0
            lastScale = 1.0
            imageOffset = .zero
            lastOffset = .zero
            Task {
                await decodeCurrentImage()
                autoOpenExternallyIfConfigured()
            }
        }
    }

    // MARK: - Open in app / share

    private var fileExtension: String {
        filePath.components(separatedBy: ".").last?.lowercased() ?? ""
    }

    private var openExternallySet: Set<String> {
        Set(openExternallyRaw.split(separator: ",").map(String.init))
    }

    private var openExternallyBinding: Binding<Bool> {
        Binding(
            get: { openExternallySet.contains(fileExtension) },
            set: { isOn in
                var set = openExternallySet
                if isOn { set.insert(fileExtension) } else { set.remove(fileExtension) }
                openExternallyRaw = set.sorted().joined(separator: ",")
            }
        )
    }

    /// If this file's extension is marked "always open externally", present the
    /// open-in sheet as soon as the content is available.
    private func autoOpenExternallyIfConfigured() {
        guard !fileExtension.isEmpty, openExternallySet.contains(fileExtension) else { return }
        prepareExportAndShare()
    }

    /// Write the loaded file content to a temp file with its real name and
    /// present the system share / open-in sheet.
    private func prepareExportAndShare() {
        guard let detail = viewModel.fileDetail, isCurrentFile(detail),
              let content = detail.content else { return }

        let data: Data
        if detail.encoding == "base64" {
            guard let decoded = Data(base64Encoded: content) else { return }
            data = decoded
        } else {
            data = Data(content.utf8)
        }

        let fileName = filePath.components(separatedBy: "/").last ?? "file"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AgorExport", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)

        do {
            try data.write(to: url, options: .atomic)
            exportedFileURL = url
            showShareSheet = true
            AppLogger.shared.log("[FileBrowser] exported \(fileName) (\(data.count) bytes) for open-in-app", level: .info, category: "FileBrowser")
        } catch {
            AppLogger.shared.log("[FileBrowser] export failed: \(error.localizedDescription)", level: .error, category: "FileBrowser")
        }
    }

    // MARK: - PDF preview

    @ViewBuilder
    private func pdfPreview(detail: FileDetail) -> some View {
        if let content = detail.content,
           let data = Data(base64Encoded: content),
           let document = pdfDocument(from: data) {
            PDFKitView(document: document)
        } else {
            ContentUnavailableView {
                Label("Cannot preview PDF", systemImage: "doc.richtext")
            } description: {
                Text("The PDF could not be decoded. Try \"Open in app…\" instead.")
            }
        }
    }

    /// Timed wrapper so the log shows what PDF construction costs — this runs
    /// inside a ViewBuilder, so it repeats on every body evaluation.
    private func pdfDocument(from data: Data) -> PDFDocument? {
        let start = CFAbsoluteTimeGetCurrent()
        let document = PDFDocument(data: data)
        AppLogger.shared.log(
            "[Timing] PDFDocument build \(FileBrowserViewModel.ms(since: start))ms (\(data.count) bytes)",
            level: .info, category: "FileBrowser"
        )
        return document
    }

    private func decodeCurrentImage() async {
        guard let detail = viewModel.fileDetail,
              isCurrentFile(detail),
              detail.encoding == "base64",
              isImageFile(filePath),
              let content = detail.content,
              let data = Data(base64Encoded: content) else { return }
        let start = CFAbsoluteTimeGetCurrent()
        let image = await Task.detached(priority: .userInitiated) { decodeGIF(data) }.value
        decodedImage = image
        AppLogger.shared.log(
            "[Timing] image base64+decode \(FileBrowserViewModel.ms(since: start))ms (\(data.count) bytes)",
            level: .info, category: "FileBrowser"
        )
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

    /// The loaded payload belongs to this view. A path written in a message can
    /// be worktree-relative in a shorter form than the server's canonical path,
    /// and the failed-fetch fallback resolves it against the file list — so the
    /// returned path may legitimately be a longer form of the requested one.
    private func isCurrentFile(_ detail: FileDetail) -> Bool {
        detail.path == filePath || detail.path.hasSuffix("/" + filePath)
    }

    private func isImageFile(_ path: String) -> Bool {
        let ext = path.components(separatedBy: ".").last?.lowercased() ?? ""
        return ["png", "jpg", "jpeg", "gif", "svg", "webp", "ico"].contains(ext)
    }

    private func isPDFFile(_ path: String) -> Bool {
        path.components(separatedBy: ".").last?.lowercased() == "pdf"
    }
}

// MARK: - PDFKit wrapper

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document !== document {
            uiView.document = document
        }
    }
}

// MARK: - UIActivityViewController wrapper (share / open-in-app)

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
