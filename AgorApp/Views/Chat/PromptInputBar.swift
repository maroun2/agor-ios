import SwiftUI
import PhotosUI

struct PromptInputBar: View {
    let viewModel: ChatViewModel

    @FocusState private var isFocused: Bool
    @State private var showFilePicker = false
    @State private var showPhotoPicker = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var isPressingMic = false
    @State private var holdTask: Task<Void, Never>?
    @State private var pressStartedAt: Date?

    /// How long the mic must be held before dictation starts, so a tap meant for
    /// voice mode never trips it.
    private let holdToRecordDelay: Double = 1.0

    private var dictation: DictationService { DictationService.shared }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(alignment: .center, spacing: 8) {
                if viewModel.showsInlineVoiceControls {
                    // Voice mode active - show voice status
                    voiceStatusView
                        .frame(maxWidth: .infinity)

                    // Skip TTS button — only shown while TTS is actively speaking
                    if viewModel.voiceService?.state == .speaking {
                        Button {
                            HapticFeedback.light()
                            viewModel.voiceService?.skipTTS()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.blue)
                                .frame(width: 30, height: 36)
                        }
                    }

                    // Send button — only shown while actively recording
                    if viewModel.voiceService?.state == .recording {
                        Button {
                            HapticFeedback.light()
                            viewModel.voiceService?.sendRecordingNow()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 22))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.green)
                                .frame(width: 30, height: 36)
                        }
                    }

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
                        if CrashLogService.shared.hasCrashLog {
                            Button {
                                viewModel.uploadCrashLog()
                            } label: {
                                Label("Attach Crash Log", systemImage: "ladybug")
                            }
                        }

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

                    if !viewModel.voiceModeEnabled {
                        micButton
                    }

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
                            if viewModel.isSessionQueueable {
                                Image(systemName: "text.badge.plus")
                                    .font(.system(size: 24))
                                    .foregroundStyle(.orange)
                                    .frame(width: 36, height: 36)
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 28))
                                    .symbolRenderingMode(.hierarchical)
                                    .frame(width: 36, height: 36)
                            }
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

    /// Tap enables continuous voice mode. Holding for `holdToRecordDelay` starts
    /// push-to-talk dictation instead: record until release, transcribe once, append
    /// the text to whatever is already in the field.
    ///
    /// One DragGesture drives both — a LongPressGesture sequenced with a drag (the
    /// obvious spelling) drops touches when the two recognizers disagree about who
    /// owns the press. `minimumDistance: 0` makes onChanged fire on touch-down and
    /// onEnded on lift, which is exactly the press/release pair needed here.
    private var micButton: some View {
        Group {
            if dictation.state == .transcribing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 36, height: 36)
            } else {
                Image(systemName: dictation.isRecording ? "waveform.circle.fill" : "mic.fill")
                    .font(.system(size: dictation.isRecording ? 26 : 20))
                    .foregroundStyle(dictation.isRecording ? .red : (viewModel.currentSessionId == nil ? Color.secondary : .blue))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
                    .scaleEffect(dictation.isRecording ? 1.15 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: dictation.isRecording)
                    .gesture(micGesture)
            }
        }
    }

    private var micGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard viewModel.currentSessionId != nil, !isPressingMic else { return }
                isPressingMic = true
                pressStartedAt = Date()
                holdTask = Task {
                    try? await Task.sleep(for: .seconds(holdToRecordDelay))
                    guard !Task.isCancelled else { return }
                    HapticFeedback.light()
                    await dictation.start()
                }
            }
            .onEnded { _ in
                guard isPressingMic else { return }
                isPressingMic = false
                let held = Date().timeIntervalSince(pressStartedAt ?? Date())
                pressStartedAt = nil
                let task = holdTask
                holdTask = nil

                // Tap-vs-hold is decided by elapsed time, NOT by dictation.isRecording:
                // releasing right at the threshold can land while start() is still
                // awaiting permission/audio setup, and testing isRecording there would
                // both enable voice mode and leave a recording running with no owner.
                guard held >= holdToRecordDelay else {
                    task?.cancel()
                    HapticFeedback.light()
                    viewModel.voiceModeEnabled = true
                    return
                }

                Task {
                    // Let a start() already in flight finish before stopping it.
                    await task?.value
                    guard dictation.isRecording else {
                        dictation.cancel()
                        return
                    }
                    guard let text = await dictation.stopAndTranscribe() else { return }
                    // Append — never clobber what the user already typed.
                    let existing = viewModel.promptText
                    viewModel.promptText = existing.isEmpty
                        ? text
                        : existing + (existing.hasSuffix(" ") ? "" : " ") + text
                    HapticFeedback.light()
                }
            }
    }

    private var voiceStatusView: some View {
        HStack(spacing: 8) {
            if let service = viewModel.voiceService {
                switch service.state {
                case .disabled:
                    ProgressView()
                        .controlSize(.small)
                    // With the models preloaded at launch this phase is a few
                    // hundred ms of audio setup — saying "loading" or "compiling"
                    // then is just wrong, so those texts are gated on the model
                    // actually doing that work.
                    switch service.transcription.state {
                    case .downloading(let progress) where progress > 0:
                        Text(verbatim: "Downloading model… \(Int(progress * 100))%")
                            .foregroundStyle(.secondary)
                    case .warming:
                        Text("Compiling model (first run)…")
                            .foregroundStyle(.secondary)
                    default:
                        Text(service.transcription.isReady ? "Starting…" : "Loading voice model…")
                            .foregroundStyle(.secondary)
                    }
                case .preparing:
                    ProgressView()
                        .controlSize(.small)
                    Text(service.transcription.isReady ? "Starting…" : "Preparing…")
                        .foregroundStyle(.secondary)
                case .paused:
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.secondary)
                    Text("Waiting for agent...")
                        .foregroundStyle(.secondary)
                case .listening:
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.blue)
                    AudioLevelBar(
                        audioLevel: service.vad.currentAudioLevel,
                        threshold: service.vad.energyThreshold,
                        isRecording: false
                    )
                    .frame(height: 24)
                case .recording:
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.red)
                    AudioLevelBar(
                        audioLevel: service.vad.currentAudioLevel,
                        threshold: service.vad.energyThreshold,
                        isRecording: true
                    )
                    .frame(height: 24)
                case .transcribing:
                    ProgressView()
                        .controlSize(.small)
                    Text(verbatim: service.transcriptionProgress.isEmpty ? "Transcribing..." : service.transcriptionProgress)
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
            && (viewModel.isSessionPromptable || viewModel.isSessionQueueable)
            && !viewModel.isSendingPrompt
    }

    private var placeholder: String {
        guard let session = viewModel.currentSession else { return "Type a prompt..." }
        switch session.status {
        case .running: return "Queue a message..."
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
