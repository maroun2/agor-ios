import SwiftUI

struct FileBrowserView: View {
    let viewModel: FileBrowserViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.files.isEmpty {
                    ProgressView("Loading files...")
                } else if let error = viewModel.error, viewModel.files.isEmpty {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") {
                            Task { await viewModel.loadFiles() }
                        }
                    }
                } else {
                    fileList
                }
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
                await viewModel.loadFiles()
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
                NavigationLink {
                    FileDetailView(viewModel: viewModel, filePath: file.path)
                } label: {
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
            }

            if viewModel.currentDirectories.isEmpty && viewModel.currentFiles.isEmpty {
                Text("Empty directory")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
        }
    }
}
