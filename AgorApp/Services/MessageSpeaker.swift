import AVFoundation
import Foundation

/// Reads one chosen message aloud, on demand.
///
/// Separate from ContinuousVoiceService on purpose: this is a button the user
/// presses on a specific message, with no listening, no turn taking and no
/// automatic reading of anything else. It owns its own synthesizer so tapping
/// speak outside voice mode doesn't start, or interfere with, a voice session.
@MainActor
@Observable
final class MessageSpeaker {
    static let shared = MessageSpeaker()

    @ObservationIgnored private let tts = TextToSpeechService()

    /// The message currently being read, so its button can show as active and
    /// act as a stop button.
    private(set) var speakingMessageId: String?

    private init() {
        tts.onSpeechFinished = { [weak self] in
            self?.speakingMessageId = nil
        }
    }

    /// Speak this message, or stop if it is already the one being read.
    func toggle(messageId: String, text: String) {
        guard !text.isEmpty else { return }

        if speakingMessageId == messageId {
            stop()
            return
        }

        // Spoken audio playback: honours the ringer switch being silent is not
        // wanted here — the user just asked for this out loud — and ducking
        // means podcasts and music drop rather than stop.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            AppLogger.shared.log(
                "[Voice] speak button: audio session setup failed: \(error.localizedDescription)",
                level: .warning, category: "Voice"
            )
        }

        speakingMessageId = messageId
        tts.speakFinalMessage(text)
        AppLogger.shared.log(
            "[Voice] 🔊 Speaking message \(messageId.prefix(8)) on request (\(text.count) chars)",
            level: .info, category: "Voice"
        )
    }

    func stop() {
        tts.stop()
        speakingMessageId = nil
    }

    /// The part of a message worth reading: its prose. Tool calls and tool
    /// results are structure, not something to listen to.
    static func speakableText(for message: Message) -> String? {
        let text: String
        switch message.content {
        case .text(let value):
            text = value
        case .blocks(let blocks):
            text = blocks.compactMap { block -> String? in
                if case .text(let content) = block { return content.text }
                return nil
            }.joined(separator: "\n\n")
        default:
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
