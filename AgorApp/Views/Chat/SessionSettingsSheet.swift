import SwiftUI

struct SessionSettingsSheet: View {
    let session: Session
    let socketService: SocketService
    let queuedVoiceModeEnabled: Bool
    let onQueuedVoiceModeChanged: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var permissionMode: PermissionMode
    @State private var model: String
    @State private var queuedVoiceMode: Bool
    @State private var isSaving = false
    @State private var error: String?

    init(
        session: Session,
        socketService: SocketService,
        queuedVoiceModeEnabled: Bool,
        onQueuedVoiceModeChanged: @escaping (Bool) -> Void
    ) {
        self.session = session
        self.socketService = socketService
        self.queuedVoiceModeEnabled = queuedVoiceModeEnabled
        self.onQueuedVoiceModeChanged = onQueuedVoiceModeChanged
        self._permissionMode = State(initialValue: session.permissionConfig?.mode ?? .default)
        self._model = State(initialValue: session.modelConfig?.model ?? "")
        self._queuedVoiceMode = State(initialValue: queuedVoiceModeEnabled)
    }

    var body: some View {
        NavigationStack {
            List {
                // Permission Mode
                Section {
                    ForEach(permissionModes, id: \.mode) { item in
                        Button {
                            permissionMode = item.mode
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.label)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text(item.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if permissionMode == item.mode {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                        .font(.body.weight(.semibold))
                                }
                            }
                        }
                    }
                } header: {
                    Text("Permission Mode")
                } footer: {
                    Text("Controls how the agent handles tool approvals.")
                        .font(.caption2)
                }

                // Model
                if !model.isEmpty {
                    Section("Model") {
                        Text(model)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Voice") {
                    Toggle("Queued Voice Mode", isOn: $queuedVoiceMode)
                    Text("Keep listening while the agent is busy and queue new transcripts for this session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Session Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(
                        isSaving ||
                        (
                            permissionMode == (session.permissionConfig?.mode ?? .default) &&
                            queuedVoiceMode == queuedVoiceModeEnabled
                        )
                    )
                    .bold()
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        error = nil
        do {
            let _: Session = try await socketService.servicePatch(
                service: "sessions",
                id: session.sessionId,
                data: [
                    "permission_config": ["mode": permissionMode.rawValue]
                ]
            )
            onQueuedVoiceModeChanged(queuedVoiceMode)
            dismiss()
        } catch {
            self.error = "Failed to save: \(error.localizedDescription)"
        }
        isSaving = false
    }

    private var permissionModes: [PermissionModeItem] {
        switch session.agenticTool {
        case .claudeCode:
            return [
                PermissionModeItem(mode: .default, label: "Default", description: "Ask before risky actions"),
                PermissionModeItem(mode: .acceptEdits, label: "Accept Edits", description: "Auto-approve file edits, ask for commands"),
                PermissionModeItem(mode: .bypassPermissions, label: "Bypass Permissions", description: "Auto-approve everything"),
                PermissionModeItem(mode: .plan, label: "Plan Mode", description: "Read-only research, no code changes"),
            ]
        case .codex:
            return [
                PermissionModeItem(mode: .ask, label: "Ask", description: "Ask before every action"),
                PermissionModeItem(mode: .auto, label: "Auto", description: "Auto-approve most actions"),
                PermissionModeItem(mode: .onFailure, label: "On Failure", description: "Only ask when something fails"),
                PermissionModeItem(mode: .allowAll, label: "Allow All", description: "No approval needed"),
            ]
        case .gemini:
            return [
                PermissionModeItem(mode: .default, label: "Default", description: "Standard approval flow"),
                PermissionModeItem(mode: .autoEdit, label: "Auto Edit", description: "Auto-approve file edits"),
                PermissionModeItem(mode: .yolo, label: "YOLO", description: "No approval needed"),
            ]
        default:
            return [
                PermissionModeItem(mode: .default, label: "Default", description: "Standard approval flow"),
            ]
        }
    }
}

private struct PermissionModeItem {
    let mode: PermissionMode
    let label: String
    let description: String
}
