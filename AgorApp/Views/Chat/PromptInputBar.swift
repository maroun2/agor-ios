import SwiftUI
import PhotosUI

struct PromptInputBar: View {
    let viewModel: ChatViewModel

    @FocusState private var isFocused: Bool
    @State private var showFilePicker = false
    @State private var showPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(alignment: .center, spacing: 8) {
                if viewModel.voiceModeEnabled {
                    // Voice mode active - show voice status
                    voiceStatusView
                        .frame(maxWidth: .infinity)

                    // Disable voice button
                    Button {
                        HapticFeedback.light()
                        viewModel.voiceModeEnabled = false
                    } label: {
                        Image(systemName: "mic.slash.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                    }
                } else {
                    // Text mode - normal UI
                    // Attachment menu
                    Menu {
                        Button {
                            viewModel.uploadDebugLog()
                        } label: {
                            Label("Attach Debug Log", systemImage: "ant")
                        }

                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label("Attach Photo", systemImage: "photo")
                        }

                        Button {
                            showFilePicker = true
                        } label: {
                            Label("Attach File", systemImage: "doc")
                        }
                    } label: {
                        if viewModel.isUploading {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 36, height: 36)
                        } else {
                            Image(systemName: "paperclip")
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                                .frame(width: 36, height: 36)
                        }
                    }
                    .disabled(viewModel.isUploading || viewModel.currentSessionId == nil)

                    // Text input
                    TextField(placeholder, text: Binding(
                        get: { viewModel.promptText },
                        set: { viewModel.promptText = $0 }
                    ), axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.plain)
                        .focused($isFocused)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))

                    // Voice mode toggle
                    Button {
                        HapticFeedback.light()
                        viewModel.voiceModeEnabled = true
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.blue)
                            .frame(width: 36, height: 36)
                    }
                    .disabled(viewModel.currentSessionId == nil)

                    // Send button
                    Button {
                        HapticFeedback.light()
                        viewModel.sendPrompt()
                    } label: {
                        if viewModel.isSendingPrompt {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 36, height: 36)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .symbolRenderingMode(.hierarchical)
                                .frame(width: 36, height: 36)
                        }
                    }
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.data]) { result in
            handleFileImport(result)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { _, newValue in
            handlePhotoSelection(newValue)
        }
    }

    private var voiceStatusView: some View {
        HStack(spacing: 8) {
            if let service = viewModel.voiceService {
                switch service.state {
                case .disabled:
                    // Model is loading — show progress from TranscriptionService
                    ProgressView()
                        .controlSize(.small)
                    if case .downloading(let progress) = service.transcription.state, progress > 0 {
                        Text("Loading model… \(Int(progress * 100))%")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Loading voice model…")
                            .foregroundStyle(.secondary)
                    }
                case .listening:
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.blue)
                    Text("Listening...")
                        .foregroundStyle(.secondary)
                case .recording:
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.red)
                    Text("Recording...")
                        .foregroundStyle(.primary)
                case .transcribing:
                    ProgressView()
                        .controlSize(.small)
                    Text("Transcribing...")
                        .foregroundStyle(.secondary)
                case .sending:
                    ProgressView()
                        .controlSize(.small)
                    Text("Sending...")
                        .foregroundStyle(.secondary)
                case .speaking:
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.blue)
                    Text("Speaking...")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Initializing...")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 20))
    }

    private var canSend: Bool {
        !viewModel.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && viewModel.isSessionPromptable
            && !viewModel.isSendingPrompt
    }

    private var placeholder: String {
        guard let session = viewModel.currentSession else { return "Type a prompt..." }
        switch session.status {
        case .running: return "Type your next message..."
        case .awaitingPermission: return "Waiting for permission..."
        case .awaitingInput: return "Waiting for input..."
        case .idle: return "Type a prompt..."
        default: return "Type a prompt..."
        }
    }

    private func handleFileImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else { return }
            let fileName = url.lastPathComponent
            let mimeType = mimeTypeForExtension(url.pathExtension)
            viewModel.uploadAndInsertReference(fileData: data, fileName: fileName, mimeType: mimeType)
        case .failure(let error):
            AppLogger.shared.log("[Attach] file import error: \(error.localizedDescription)", level: .error, category: "Chat")
        }
    }

    private func handlePhotoSelection(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self) {
                let fileName = "photo-\(Int(Date().timeIntervalSince1970)).jpg"
                viewModel.uploadAndInsertReference(fileData: data, fileName: fileName, mimeType: "image/jpeg")
            }
        }
        selectedPhoto = nil
    }

    private func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "txt": return "text/plain"
        case "json": return "application/json"
        case "pdf": return "application/pdf"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "md": return "text/markdown"
        case "swift": return "text/x-swift"
        case "ts", "tsx": return "text/typescript"
        case "js", "jsx": return "text/javascript"
        case "py": return "text/x-python"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }
}
