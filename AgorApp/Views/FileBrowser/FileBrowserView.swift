import SwiftUI

struct FileBrowserView: View {
    let viewModel: FileBrowserViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var shareURL: URL?
    @State private var isPreparingShare = false
    @State private var navigationPath = NavigationPath()
    /// Sheet was opened directly onto a file from a chat link — that download
    /// takes priority over the worktree file list.
    @State private var openedOnFile = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if viewModel.isLoading && viewModel.files.isEmpty {
                    ProgressView("Loading files...")
                } else if let error = viewModel.error, viewModel.files.isEmpty {
                    ContentUnavailableView {
                        Label(
                            viewModel.isWorktreeGone ? "Worktree Removed" : "Error",
                            systemImage: viewModel.isWorktreeGone ? "trash" : "exclamationmark.triangle"
                        )
                    } description: {
                        Text(error)
                    } actions: {
                        if viewModel.isWorktreeGone {
                            Button("Close") { dismiss() }
                        } else {
                            Button("Retry") {
                                Task { await viewModel.loadFiles(force: true) }
                            }
                        }
                    }
                } else {
                    fileList
                }
            }
            .navigationDestination(for: String.self) { filePath in
                FileDetailView(viewModel: viewModel, filePath: filePath)
            }
            .navigationTitle(viewModel.currentPath.isEmpty ? "Files" : viewModel.currentPath.components(separatedBy: "/").last ?? "Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                if !viewModel.currentPath.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            viewModel.navigateToRoot()
                        } label: {
                            Image(systemName: "house")
                        }
                    }
                }
            }
            .task {
                // Opened straight onto a file (a chat link): download that file
                // first and let the tree scan wait, so the thing the user asked
                // for isn't queued behind a full worktree walk on the daemon.
                if openedOnFile {
                    // Give the detail view a moment to start its own fetch before
                    // sampling isLoadingFile, which it sets on appear.
                    try? await Task.sleep(for: .milliseconds(200))
                    while viewModel.isLoadingFile {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                await viewModel.loadFiles()
            }
            .refreshable {
                await viewModel.loadFiles(force: true)
            }
            .onAppear {
                if let pending = viewModel.pendingFilePath {
                    viewModel.pendingFilePath = nil
                    openedOnFile = true
                    navigationPath.append(pending)
                }
            }
        }
    }

    private var fileList: some View {
        List {
            // Back button
            if !viewModel.currentPath.isEmpty {
                Button {
                    viewModel.navigateUp()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.caption)
                            .foregroundStyle(.blue)
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)
                        Text("..")
                            .foregroundStyle(.primary)
                    }
                }
            }

            // Directories
            ForEach(viewModel.currentDirectories, id: \.self) { dir in
                Button {
                    viewModel.navigateTo(dir)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                        Text(dir)
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // Files
            ForEach(viewModel.currentFiles) { file in
                NavigationLink(value: file.path) {
                    HStack(spacing: 8) {
                        Image(systemName: file.iconName)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.fileName)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(file.formattedSize)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .contextMenu {
                    Button {
                        Task { await prepareFileForShare(file) }
                    } label: {
                        Label("Share / Open in...", systemImage: "square.and.arrow.up")
                    }
                }
            }

            if viewModel.currentDirectories.isEmpty && viewModel.currentFiles.isEmpty {
                Text("Empty directory")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
        .sheet(item: Binding(
            get: { shareURL.map { ShareItem(url: $0) } },
            set: { if $0 == nil { shareURL = nil } }
        )) { item in
            ShareSheet(url: item.url)
        }
    }

    private func prepareFileForShare(_ file: FileListItem) async {
        isPreparingShare = true
        defer { isPreparingShare = false }

        do {
            let (data, fileName) = try await viewModel.fetchFileData(file.path)
            let tempDir = FileManager.default.temporaryDirectory
            let tempURL = tempDir.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: tempURL)
            try data.write(to: tempURL)
            shareURL = tempURL
        } catch {
            // Non-fatal — share just won't appear
        }
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
