import SwiftUI

struct VADSettingsView: View {
    let chatVM: ChatViewModel

    // Local copy so sliders are responsive; written back to chatVM on change
    @State private var config: VADConfig
    @State private var sensitivity: Float

    init(chatVM: ChatViewModel) {
        self.chatVM = chatVM
        _config = State(initialValue: chatVM.vadConfig)
        let saved = UserDefaults.standard.object(forKey: "agor.vad.sensitivity") as? Float
        _sensitivity = State(initialValue: chatVM.voiceService?.vad.sensitivityLevel ?? saved ?? 0.5)
    }

    var body: some View {
        List {
            Section("Detection") {
                SliderRow(
                    label: "Sensitivity",
                    value: $sensitivity,
                    range: 0...1,
                    step: 0.05,
                    format: { String(format: "%.2f", $0) }
                ) {
                    chatVM.voiceService?.vad.setSensitivity(sensitivity)
                    UserDefaults.standard.set(sensitivity, forKey: "agor.vad.sensitivity")
                }

                SliderRow(
                    label: "Silence before send",
                    value: Binding(
                        get: { Float(config.silenceDuration) },
                        set: { config.silenceDuration = TimeInterval($0) }
                    ),
                    range: 0.3...10,
                    step: 0.1,
                    format: { String(format: "%.1fs", $0) },
                    onEditingChanged: { persistConfig() }
                )
            }

            Section {
                Button("Reset to defaults", role: .destructive) {
                    config = VADConfig()
                    sensitivity = 0.5
                    chatVM.vadConfig = config
                    chatVM.voiceService?.vad.setSensitivity(0.5)
                    UserDefaults.standard.set(Float(0.5), forKey: "agor.vad.sensitivity")
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .navigationTitle("Detection Settings")
        .navigationBarTitleDisplayMode(.inline)
        // Apply config to VAD instantly on every slider drag frame
        .onChange(of: config) { _, newConfig in
            chatVM.voiceService?.vad.config = newConfig
        }
    }

    /// Save to UserDefaults (called on slider release — avoid writes during drag)
    private func persistConfig() {
        chatVM.vadConfig = config
    }
}

// MARK: - SliderRow

private struct SliderRow: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let step: Float
    let format: (Float) -> String
    var onEditingChanged: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step) { editing in
                if !editing { onEditingChanged?() }
            }
        }
        .padding(.vertical, 2)
    }
}
