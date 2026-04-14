import Foundation
import AVFoundation
import AudioToolbox

@Observable
final class ContinuousVoiceService {
    enum State {
        case disabled
        case listening      // VAD active, waiting for speech
        case recording      // User speaking, capturing
        case transcribing   // Processing with Whisper
        case sending        // Sending to agent
        case speaking       // TTS speaking to user
    }

    // System sound IDs for audio feedback
    private enum SoundID {
        static let listeningReady: SystemSoundID = 1057  // SMS received tone
        static let recordingStart: SystemSoundID = 1113  // Begin recording
        static let messageSent: SystemSoundID = 1016     // Tock/sent sound
    }

    var state: State = .disabled
    var currentAudioLevel: Float = 0.0
    var transcriptionProgress: String = ""

    private let vad: VoiceActivityDetector
    let transcription: TranscriptionService  // Exposed for initialization
    private let tts: TextToSpeechService
    private var audioRecorder: AVAudioRecorder?
    private var currentRecordingURL: URL?

    // Callbacks
    var onTranscription: ((String) -> Void)?

    init(transcriptionService: TranscriptionService, ttsService: TextToSpeechService) {
        self.vad = VoiceActivityDetector()
        self.transcription = transcriptionService
        self.tts = ttsService

        setupCallbacks()
    }

    convenience init() {
        let transcriptionService = TranscriptionService()
        let ttsService = TextToSpeechService()
        self.init(transcriptionService: transcriptionService, ttsService: ttsService)
    }

    // MARK: - Setup

    private func setupCallbacks() {
        // VAD callbacks
        vad.onSpeechStart = { [weak self] in
            self?.handleSpeechStart()
        }

        vad.onSpeechEnd = { [weak self] in
            self?.handleSpeechEnd()
        }

        // TTS callbacks
        tts.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                self?.state = .speaking
            }
        }

        tts.onSpeechFinished = { [weak self] in
            Task { @MainActor in
                // Resume listening after TTS finishes
                if self?.state == .speaking {
                    self?.state = .listening
                }
            }
        }
    }

    // MARK: - Control

    func startListening() throws {
        guard state == .disabled else { return }

        try vad.startListening()
        state = .listening
        AudioServicesPlaySystemSound(SoundID.listeningReady)
        AppLogger.shared.log("[Voice] Continuous voice mode started", level: .info, category: "Voice")

        // Start pre-roll recorder immediately so first word is never cut off
        startPreRollRecorder()
    }

    func stopListening() {
        vad.stopListening()
        audioRecorder?.stop()
        audioRecorder = nil
        if let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
            currentRecordingURL = nil
        }
        tts.stop()
        state = .disabled
        AppLogger.shared.log("[Voice] Continuous voice mode stopped", level: .info, category: "Voice")
    }

    // MARK: - Speech Handlers

    private func handleSpeechStart() {
        guard state == .listening else {
            AppLogger.shared.log("[Voice] ⚠️ Speech start ignored - not in listening state (current: \(state))", level: .warning, category: "Voice")
            return
        }

        AppLogger.shared.log("[Voice] 🎬 Speech detected - recorder already running (pre-roll active)", level: .info, category: "Voice")

        // Stop TTS if speaking (user can interrupt)
        if tts.isSpeaking {
            AppLogger.shared.log("[Voice] 🛑 Stopping TTS - user is speaking", level: .debug, category: "Voice")
            tts.stop()
        }

        // Recorder is already running from pre-roll — just transition state
        state = .recording
        AudioServicesPlaySystemSound(SoundID.recordingStart)
        AppLogger.shared.log("[Voice] 🔴 STATE: listening → recording", level: .info, category: "Voice")
    }

    private func handleSpeechEnd() {
        guard state == .recording else {
            AppLogger.shared.log("[Voice] ⚠️ Speech end ignored - not in recording state (current: \(state))", level: .warning, category: "Voice")
            return
        }

        AppLogger.shared.log("[Voice] 🎬 Speech end triggered - stopping recording and transcribing", level: .info, category: "Voice")

        Task {
            await stopRecordingAndTranscribe()
        }
    }

    // MARK: - Recording

    private func startPreRollRecorder() {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "voice-\(UUID().uuidString).m4a"
        let fileURL = tempDir.appendingPathComponent(fileName)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder?.record()
            currentRecordingURL = fileURL
            AppLogger.shared.log("[Voice] ✅ Pre-roll recorder started: \(fileName)", level: .info, category: "Voice")
        } catch {
            AppLogger.shared.log("[Voice] ❌ Pre-roll recorder failed: \(error.localizedDescription)", level: .error, category: "Voice")
        }
    }

    private func stopRecordingAndTranscribe() async {
        AppLogger.shared.log("[Voice] 🛑 Stopping recording...", level: .info, category: "Voice")
        audioRecorder?.stop()
        audioRecorder = nil

        guard let audioURL = currentRecordingURL else {
            AppLogger.shared.log("[Voice] ⚠️ No recording URL found", level: .warning, category: "Voice")
            state = .listening
            return
        }

        // Check file size
        if let fileSize = try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? UInt64 {
            AppLogger.shared.log("[Voice] 📊 Recording file size: \(fileSize) bytes", level: .debug, category: "Voice")
        }

        state = .transcribing
        AppLogger.shared.log("[Voice] ⚙️ STATE: recording → transcribing", level: .info, category: "Voice")
        transcriptionProgress = "Transcribing..."

        do {
            let text = try await transcription.transcribe(audioURL: audioURL)

            // Clean up temp file
            try? FileManager.default.removeItem(at: audioURL)
            currentRecordingURL = nil

            guard !text.isEmpty else {
                AppLogger.shared.log("[Voice] ⚠️ Transcription empty, ignoring", level: .warning, category: "Voice")
                state = .listening
                AppLogger.shared.log("[Voice] 🔵 STATE: transcribing → listening", level: .info, category: "Voice")
                return
            }

            state = .sending
            AppLogger.shared.log("[Voice] 📤 STATE: transcribing → sending", level: .info, category: "Voice")
            AppLogger.shared.log("[Voice] ✅ Raw transcription: \"\(text)\"", level: .info, category: "Voice")

            // Strip WhisperKit special tokens (e.g., [BLANK_AUDIO], [MUSIC], etc.)
            let cleanedText = text.replacingOccurrences(
                of: "\\[[A-Z_]+\\]",
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)

            if !cleanedText.isEmpty {
                AppLogger.shared.log("[Voice] ✅ Delivering cleaned transcription: \"\(cleanedText)\"", level: .info, category: "Voice")
                AudioServicesPlaySystemSound(SoundID.messageSent)
                onTranscription?(cleanedText)
            } else {
                AppLogger.shared.log("[Voice] ⚠️ Transcription only contains special tokens, ignoring", level: .warning, category: "Voice")
            }

            // Return to listening state and start new pre-roll recorder
            state = .listening
            AppLogger.shared.log("[Voice] 🔵 STATE: sending → listening", level: .info, category: "Voice")
            startPreRollRecorder()
        } catch {
            AppLogger.shared.log("[Voice] ❌ Transcription error: \(error.localizedDescription)", level: .error, category: "Voice")
            state = .listening
            AppLogger.shared.log("[Voice] 🔵 STATE: transcribing → listening (error)", level: .info, category: "Voice")

            // Clean up temp file on error
            try? FileManager.default.removeItem(at: audioURL)
            currentRecordingURL = nil
            startPreRollRecorder()
        }
    }

    // MARK: - TTS

    func speakStatus(_ status: String) {
        tts.speakStatus(status)
    }

    func speakMessage(_ message: String) {
        tts.speakMessage(message)
    }

    // MARK: - Configuration

    func setSensitivity(_ sensitivity: Float) {
        vad.setSensitivity(sensitivity)
    }

    func setStatusSpeakingRate(_ rate: Float) {
        tts.setStatusRate(rate)
    }

    func setMessageSpeakingRate(_ rate: Float) {
        tts.setMessageRate(rate)
    }
}
