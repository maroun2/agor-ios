import SwiftUI

struct PromptInputBar: View {
    let viewModel: ChatViewModel

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(alignment: .bottom, spacing: 8) {
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

                // Send button
                Button {
                    HapticFeedback.light()
                    viewModel.sendPrompt()
                } label: {
                    if viewModel.isSendingPrompt {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 36))
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
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
}
