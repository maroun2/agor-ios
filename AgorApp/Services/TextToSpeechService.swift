import Foundation
import AVFoundation

@Observable
final class TextToSpeechService: NSObject, AVSpeechSynthesizerDelegate {
    enum SpeechType {
        case status
        case finalMessage
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?
    private var currentType: SpeechType = .status

    // Configuration
    private var statusRate: Float = 0.6  // Faster for status updates
    private var messageRate: Float = 0.5  // Normal for final messages

    var isSpeaking: Bool {
        synthesizer.isSpeaking
    }

    // Callbacks
    var onSpeechStarted: (() -> Void)?
    var onSpeechFinished: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Configuration

    func setStatusRate(_ rate: Float) {
        statusRate = max(0.3, min(0.8, rate))
    }

    func setMessageRate(_ rate: Float) {
        messageRate = max(0.3, min(0.7, rate))
    }

    // MARK: - Speech

    func speakStatus(_ text: String) {
        // Cancel any currently speaking status (skip-to-latest)
        if synthesizer.isSpeaking && currentType == .status {
            AppLogger.shared.log("[Voice] 🔄 Canceling previous status to speak new status", level: .debug, category: "Voice")
            synthesizer.stopSpeaking(at: .immediate)
        }

        guard !text.isEmpty else { return }

        // Ensure audio session supports playback
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true)
            AppLogger.shared.log("[Voice] ✅ Audio session activated for TTS", level: .debug, category: "Voice")
        } catch {
            AppLogger.shared.log("[Voice] ⚠️ Failed to activate audio session: \(error.localizedDescription)", level: .warning, category: "Voice")
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = statusRate
        utterance.volume = 1.0

        currentUtterance = utterance
        currentType = .status

        synthesizer.speak(utterance)

        AppLogger.shared.log("[Voice] 🔊 Speaking status: \"\(text)\" (rate: \(String(format: "%.2f", statusRate)))", level: .info, category: "Voice")
    }

    func speakMessage(_ text: String) {
        // Cancel status if speaking, then speak message
        if synthesizer.isSpeaking {
            AppLogger.shared.log("[Voice] 🔄 Canceling previous speech to speak final message", level: .debug, category: "Voice")
            synthesizer.stopSpeaking(at: .immediate)
        }

        guard !text.isEmpty else { return }

        // Ensure audio session supports playback
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true)
            AppLogger.shared.log("[Voice] ✅ Audio session activated for TTS", level: .debug, category: "Voice")
        } catch {
            AppLogger.shared.log("[Voice] ⚠️ Failed to activate audio session: \(error.localizedDescription)", level: .warning, category: "Voice")
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = messageRate
        utterance.volume = 1.0

        currentUtterance = utterance
        currentType = .finalMessage

        synthesizer.speak(utterance)

        AppLogger.shared.log("[Voice] 💬 Speaking final message: \"\(text.prefix(50))\(text.count > 50 ? "..." : "")\" (\(text.count) chars, rate: \(String(format: "%.2f", messageRate)))", level: .info, category: "Voice")
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        currentUtterance = nil
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onSpeechStarted?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        currentUtterance = nil
        onSpeechFinished?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        currentUtterance = nil
        // Don't call onSpeechFinished for cancellations
    }
}
