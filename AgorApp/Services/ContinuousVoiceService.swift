import Foundation
import AVFoundation

@Observable
final class ContinuousVoiceService {
    enum State {
        case disabled
        case listening      // VAD active, waiting for speech
        case paused         // VAD stopped while agent is running
        case recording      // User speaking, capturing
        case transcribing   // Processing with Whisper
        case sending        // Sending to agent
        case speaking       // TTS speaking to user
    }

    // Kept alive for the tone duration
    private var toneEngine: AVAudioEngine?

    var state: State = .disabled
    var currentAudioLevel: Float = 0.0
    var transcriptionProgress: String = ""

    let vad: VoiceActivityDetector
    let transcription: TranscriptionService  // Exposed for initialization
    private let tts: TextToSpeechService
    private var audioRecorder: AVAudioRecorder?
    private var currentRecordingURL: URL?
    private var preRollRestartTimer: Timer?
    private let preRollMaxDuration: TimeInterval = 2.0  // Max pre-roll buffer before speech

    // Callbacks
    var onTranscription: ((String) -> Void)?
    var onTTSFinished: (() -> Void)?

    // Pause state (VAD stopped but mode still active, e.g. while agent is running)
    private(set) var isPaused = false
    var isTTSSpeaking: Bool { tts.isSpeaking }

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
                if self?.state == .speaking {
                    self?.state = (self?.isPaused == true) ? .paused : .listening
                }
                // Notify ChatViewModel so it can resume listening now that TTS is done
                self?.onTTSFinished?()
            }
        }
    }

    // MARK: - Control

    func startListening() throws {
        guard state == .disabled else { return }

        try vad.startListening()
        state = .listening
        AppLogger.shared.log("[Voice] 🔔 Playing beep: listeningReady", level: .info, category: "Voice")
        playTone(frequency: 1046, duration: 0.08)  // C6 — "ready" ding
        AppLogger.shared.log("[Voice] Continuous voice mode started", level: .info, category: "Voice")

        // Start pre-roll recorder immediately so first word is never cut off
        startPreRollRecorder()
    }

    func stopListening() {
        cancelPreRollTimer()
        vad.stopListening()
        audioRecorder?.stop()
        audioRecorder = nil
        if let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
            currentRecordingURL = nil
        }
        tts.stop()
        isPaused = false
        state = .disabled
        AppLogger.shared.log("[Voice] Continuous voice mode stopped", level: .info, category: "Voice")
    }

    // Pause VAD while agent is running — keeps voice mode active, no beep on resume
    func pauseListening() {
        guard !isPaused, state != .disabled else { return }
        cancelPreRollTimer()
        vad.stopListening()
        audioRecorder?.stop()
        audioRecorder = nil
        if let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
            currentRecordingURL = nil
        }
        isPaused = true
        state = .paused
        AppLogger.shared.log("[Voice] ⏸️ Voice paused (agent running)", level: .info, category: "Voice")
    }

    func resumeListening() throws {
        guard isPaused else { return }
        try vad.startListening()
        isPaused = false
        state = .listening
        startPreRollRecorder()
        AppLogger.shared.log("[Voice] ▶️ Voice resumed", level: .info, category: "Voice")
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
        cancelPreRollTimer()
        state = .recording
        AppLogger.shared.log("[Voice] 🔔 Playing beep: recordingStart", level: .info, category: "Voice")
        playTone(frequency: 880, duration: 0.07)  // A5 — "start recording"
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
        // Stop previous pre-roll file and clean up
        audioRecorder?.stop()
        if let old = currentRecordingURL {
            try? FileManager.default.removeItem(at: old)
            currentRecordingURL = nil
        }
        audioRecorder = nil

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

        // Rolling restart: keep pre-roll buffer short to avoid capturing TTS or old audio
        preRollRestartTimer?.invalidate()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.preRollRestartTimer = Timer.scheduledTimer(withTimeInterval: self.preRollMaxDuration, repeats: false) { [weak self] _ in
                guard let self, self.state == .listening else { return }
                AppLogger.shared.log("[Voice] 🔄 Rolling pre-roll restart (keeps buffer ≤ \(self.preRollMaxDuration)s)", level: .debug, category: "Voice")
                self.startPreRollRecorder()
            }
        }
    }

    private func cancelPreRollTimer() {
        preRollRestartTimer?.invalidate()
        preRollRestartTimer = nil
    }

    /// Play a short sine-wave tone through AVAudioEngine.
    /// AVAudioEngine is used (not AudioServicesPlaySystemSound) because:
    /// - It routes through the media/playback path at the same volume as TTS speech
    /// - AudioServicesPlaySystemSound uses the ringer path which is typically quieter
    /// - It works while .playAndRecord audio session is active
    private func playTone(frequency: Float, duration: Double, amplitude: Float = 0.85) {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        let sampleRate: Double = 44100
        let frames = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Float(i) / Float(sampleRate)
            let envelope = 1.0 - (t / Float(duration))  // linear fade-out avoids click
            data[i] = sin(2.0 * .pi * frequency * t) * amplitude * envelope
        }

        do {
            try engine.start()
        } catch {
            AppLogger.shared.log("[Voice] ⚠️ Tone engine start failed: \(error.localizedDescription)", level: .warning, category: "Voice")
            return
        }

        toneEngine = engine
        player.scheduleBuffer(buffer, completionHandler: nil)
        player.play()

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.15) { [weak self] in
            self?.toneEngine?.stop()
            self?.toneEngine = nil
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

        // Tick elapsed time so user sees progress
        let transcribeStart = Date()
        let tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }
                let elapsed = Int(Date().timeIntervalSince(transcribeStart))
                if elapsed > 0 {
                    self?.transcriptionProgress = "Transcribing... (\(elapsed)s)"
                }
            }
        }

        do {
            let text = try await transcription.transcribe(audioURL: audioURL)
            tickTask.cancel()

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
                AppLogger.shared.log("[Voice] 🔔 Playing beep: messageSent", level: .info, category: "Voice")
                playTone(frequency: 660, duration: 0.08)  // E5 — "sent" tock
                onTranscription?(cleanedText)

                // Auto-pause after sending — wait for agent to respond.
                // updateVoiceListening() will resume once session goes idle.
                isPaused = true
                state = .paused
                AppLogger.shared.log("[Voice] ⏸️ STATE: sending → paused (waiting for agent)", level: .info, category: "Voice")
            } else {
                AppLogger.shared.log("[Voice] ⚠️ Transcription only contains special tokens, ignoring", level: .warning, category: "Voice")
                // Nothing was sent — return to listening normally
                state = .listening
                AppLogger.shared.log("[Voice] 🔵 STATE: sending → listening (nothing sent)", level: .info, category: "Voice")
                startPreRollRecorder()
            }
        } catch {
            tickTask.cancel()
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

    func speakStreamChunk(_ chunk: String) {
        tts.speakStreamChunk(chunk)
    }

    func speakMessage(_ message: String) {
        tts.speakMessage(message)
    }

    func speakFinalMessage(_ message: String) {
        tts.speakFinalMessage(message)
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
