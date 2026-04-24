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

                SliderRow(
                    label: "Trigger frames (M)",
                    value: Binding(
                        get: { Float(config.confirmationRequired) },
                        set: { config.confirmationRequired = Int($0) }
                    ),
                    range: 1...10,
                    step: 1,
                    format: { "\(Int($0)) of \(config.confirmationWindow)" },
                    onEditingChanged: { persistConfig() }
                )

                SliderRow(
                    label: "Trigger window (N)",
                    value: Binding(
                        get: { Float(config.confirmationWindow) },
                        set: { config.confirmationWindow = max(Int($0), config.confirmationRequired) }
                    ),
                    range: 2...20,
                    step: 1,
                    format: { "~\(Int($0 * 1000 / 47))ms" },
                    onEditingChanged: { persistConfig() }
                )

                SliderRow(
                    label: "Floor freeze",
                    value: Binding(
                        get: { Float(config.noiseFloorFreezeFrames) },
                        set: { config.noiseFloorFreezeFrames = Int($0) }
                    ),
                    range: 0...60,
                    step: 1,
                    format: { "~\(Int($0 * 1000 / 47))ms" },
                    onEditingChanged: { persistConfig() }
                )
            }

            Section("Noise Floor") {
                SliderRow(
                    label: "Max ambient level",
                    value: $config.maxNoiseFloor,
                    range: 0.001...0.200,
                    step: 0.001,
                    format: { String(format: "%.3f", $0) },
                    onEditingChanged: { persistConfig() }
                )

                SliderRow(
                    label: "Rise speed",
                    value: $config.noiseFloorRiseAlpha,
                    range: 0...0.200,
                    step: 0.001,
                    format: { $0 == 0 ? "OFF" : String(format: "%.3f", $0) },
                    onEditingChanged: { persistConfig() }
                )

                SliderRow(
                    label: "Suppress gate",
                    value: $config.suppressRiseGateMultiplier,
                    range: 1.0...5.0,
                    step: 0.1,
                    format: { String(format: "%.1f× floor", $0) },
                    onEditingChanged: { persistConfig() }
                )

                SliderRow(
                    label: "Hysteresis gap",
                    value: $config.hysteresisRatio,
                    range: 0.20...0.95,
                    step: 0.05,
                    format: { String(format: "%.0f%%", $0 * 100) },
                    onEditingChanged: { persistConfig() }
                )
            }

            Section("EMA Smoothing") {
                SliderRow(
                    label: "Attack speed",
                    value: $config.emaAttackAlpha,
                    range: 0.05...0.90,
                    step: 0.05,
                    format: { String(format: "%.2f", $0) },
                    onEditingChanged: { persistConfig() }
                )

                SliderRow(
                    label: "Release speed",
                    value: $config.emaReleaseAlpha,
                    range: 0.01...0.50,
                    step: 0.01,
                    format: { String(format: "%.2f", $0) },
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
