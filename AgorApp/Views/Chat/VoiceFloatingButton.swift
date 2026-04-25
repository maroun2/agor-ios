import SwiftUI

struct VoiceFloatingButton: View {
    let voiceState: ContinuousVoiceService.State
    let action: () -> Void

    private var backgroundColor: Color {
        switch voiceState {
        case .listening, .recording:
            return .blue
        case .calibrating, .transcribing, .sending, .speaking:
            return .orange
        case .paused, .disabled:
            return .gray
        }
    }

    private var iconName: String {
        switch voiceState {
        case .listening, .recording:
            return "mic.fill"
        case .calibrating:
            return "waveform"
        case .speaking:
            return "speaker.wave.2.fill"
        case .transcribing, .sending:
            return "waveform"
        case .paused, .disabled:
            return "mic.slash.fill"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                Text("Back to Voice")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(backgroundColor, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        }
    }
}
