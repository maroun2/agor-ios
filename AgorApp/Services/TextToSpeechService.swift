import Foundation
import AVFoundation

@MainActor
@Observable
final class TextToSpeechService: NSObject, @preconcurrency AVSpeechSynthesizerDelegate {
    enum SpeechType {
        case status
        case streamChunk   // Streaming TTS — queues naturally, interrupted by status
        case finalMessage
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?
    private var currentType: SpeechType = .status

    // Best available English voice: premium → enhanced → default compact
    // Computed once at init (lazy var incompatible with @Observable)
    private let bestVoice: AVSpeechSynthesisVoice?

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
        bestVoice = AVSpeechSynthesisVoice.bestAvailable()
        if let voice = bestVoice {
            AppLogger.shared.log("[Voice] 🎙️ Using voice: \(voice.name) [\(voice.identifier)] quality=\(voice.quality.rawValue)", level: .info, category: "Voice")
        } else {
            AppLogger.shared.log("[Voice] 🎙️ No voice available — system default", level: .warning, category: "Voice")
        }
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
        // Cancel status or stream chunks — important status is always skip-to-latest
        if synthesizer.isSpeaking && (currentType == .status || currentType == .streamChunk) {
            AppLogger.shared.log("[Voice] 🔄 Canceling previous \(currentType) to speak new status", level: .debug, category: "Voice")
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
        utterance.voice = bestVoice
        utterance.rate = statusRate
        utterance.volume = 1.0

        currentUtterance = utterance
        currentType = .status

        synthesizer.speak(utterance)

        AppLogger.shared.log("[Voice] 🔊 Speaking status: \"\(text)\" (rate: \(String(format: "%.2f", statusRate)))", level: .info, category: "Voice")
    }

    func speakMessage(_ text: String) {
        // Only interrupt status speech; queue naturally behind other messages
        if synthesizer.isSpeaking && currentType == .status {
            AppLogger.shared.log("[Voice] 🔄 Canceling status to speak message", level: .debug, category: "Voice")
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
        utterance.voice = bestVoice
        utterance.rate = messageRate
        utterance.volume = 1.0

        currentUtterance = utterance
        currentType = .finalMessage

        synthesizer.speak(utterance)

        AppLogger.shared.log("[Voice] 💬 Speaking message: \"\(text.prefix(50))\(text.count > 50 ? "..." : "")\" (\(text.count) chars, rate: \(String(format: "%.2f", messageRate)))", level: .info, category: "Voice")
    }

    /// Speak a streaming text chunk — queues naturally (no self-interruption).
    /// Interrupted by speakStatus (important announcements take priority).
    func speakStreamChunk(_ text: String) {
        guard !text.isEmpty else { return }
        // Only interrupt status speech; stream chunks queue behind each other
        if synthesizer.isSpeaking && currentType == .status {
            synthesizer.stopSpeaking(at: .immediate)
        }

        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {}

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestVoice
        utterance.rate = messageRate
        utterance.volume = 1.0

        currentType = .streamChunk
        synthesizer.speak(utterance)

        AppLogger.shared.log("[Voice] 🎙️ Stream chunk: \"\(text.prefix(50))\"", level: .debug, category: "Voice")
    }

    func speakFinalMessage(_ text: String, type: SpeechType = .finalMessage) {
        // Clear queue and speak immediately — used for the final response
        if synthesizer.isSpeaking {
            AppLogger.shared.log("[Voice] 🔄 Clearing queue to speak final message", level: .debug, category: "Voice")
            synthesizer.stopSpeaking(at: .immediate)
        }

        guard !text.isEmpty else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(true)
        } catch {
            AppLogger.shared.log("[Voice] ⚠️ Failed to activate audio session: \(error.localizedDescription)", level: .warning, category: "Voice")
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = bestVoice
        utterance.rate = messageRate
        utterance.volume = 1.0

        currentUtterance = utterance
        currentType = type

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
