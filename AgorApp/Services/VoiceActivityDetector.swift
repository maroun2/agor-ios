import Foundation
import AVFoundation

@Observable
final class VoiceActivityDetector {
    enum State {
        case idle
        case listening
        case speechDetected
    }

    var state: State = .idle
    var currentAudioLevel: Float = 0.0

    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?

    // VAD configuration
    private(set) var energyThreshold: Float = 0.008  // Speech start threshold
    private var silenceThreshold: Float = 0.003  // Silence threshold
    private let silenceDuration: TimeInterval = 1.0  // Seconds of silence to detect end (faster response)

    private var lastSoundTime: Date = Date()
    private var speechStartTime: Date?
    private var silenceCheckTimer: Timer?
    private var bufferCount: Int = 0  // For periodic logging

    // Callbacks
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?

    // MARK: - Configuration

    func setSensitivity(_ sensitivity: Float) {
        // sensitivity: 0.0 (low) to 1.0 (high)
        // Adjust thresholds based on sensitivity
        energyThreshold = 0.01 + (sensitivity * 0.05)  // 0.01 - 0.06
        silenceThreshold = 0.005 + (sensitivity * 0.015)  // 0.005 - 0.02
    }

    // MARK: - Start/Stop

    func startListening() throws {
        guard state == .idle else { return }

        // Request microphone permission
        let session = AVAudioSession.sharedInstance()

        // Check permission status
        switch session.recordPermission {
        case .denied:
            throw VADError.microphonePermissionDenied
        case .undetermined:
            // Request permission synchronously (blocks until user responds)
            var granted = false
            let semaphore = DispatchSemaphore(value: 0)
            session.requestRecordPermission { allowed in
                granted = allowed
                semaphore.signal()
            }
            semaphore.wait()

            if !granted {
                throw VADError.microphonePermissionDenied
            }
        case .granted:
            break
        @unknown default:
            break
        }

        // Setup audio session for recording + playback (for TTS)
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        // Setup audio engine
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        inputNode = engine.inputNode
        guard let input = inputNode else { return }

        // Install tap on input node
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        // Start engine
        try engine.start()
        state = .listening

        // Start silence check timer
        startSilenceCheckTimer()

        AppLogger.shared.log("[Voice] VAD started listening", level: .info, category: "Voice")
    }

    func stopListening() {
        guard state != .idle else { return }

        silenceCheckTimer?.invalidate()
        silenceCheckTimer = nil

        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        inputNode = nil

        state = .idle

        AppLogger.shared.log("[Voice] VAD stopped listening", level: .info, category: "Voice")
    }

    // MARK: - Audio Processing

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData?[0] else {
            AppLogger.shared.log("[Voice] ⚠️ No audio data in buffer", level: .warning, category: "Voice")
            return
        }
        let frameLength = Int(buffer.frameLength)

        // Calculate RMS (root mean square) of audio
        var sum: Float = 0
        for i in 0..<frameLength {
            sum += floatData[i] * floatData[i]
        }
        let rms = sqrt(sum / Float(frameLength))

        Task { @MainActor in
            self.currentAudioLevel = rms
        }

        // Log RMS periodically (every ~100 buffers = ~2 seconds at 48kHz)
        bufferCount += 1
        if bufferCount % 100 == 0 {
            AppLogger.shared.log("[Voice] 📊 Audio level: RMS=\(String(format: "%.4f", rms)), energyThresh=\(String(format: "%.4f", self.energyThreshold)), state=\(self.state)", level: .info, category: "Voice")
        }

        // Speech detection logic
        if state == .listening && rms > energyThreshold {
            // Speech detected!
            Task { @MainActor in
                self.speechStartTime = Date()
                self.state = .speechDetected
                AppLogger.shared.log("[Voice] 🎤 Speech START detected (RMS: \(String(format: "%.4f", rms)) > threshold: \(String(format: "%.4f", self.energyThreshold)))", level: .info, category: "Voice")
                self.onSpeechStart?()
            }
        }

        // Update last sound time if audio is above silence threshold
        if rms > silenceThreshold {
            lastSoundTime = Date()
        }

        // Debug: Log RMS values when recording
        if state == .speechDetected {
            let silenceDur = Date().timeIntervalSince(lastSoundTime)
            AppLogger.shared.log("[Voice] 🎙️ Recording: RMS=\(String(format: "%.4f", rms)), silence=\(String(format: "%.1f", silenceDur))s", level: .debug, category: "Voice")
        }
    }

    private func startSilenceCheckTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.silenceCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.checkForSilence()
            }
        }
    }

    private func checkForSilence() {
        guard state == .speechDetected else { return }

        let silenceDuration = Date().timeIntervalSince(lastSoundTime)
        if silenceDuration >= self.silenceDuration {
            // Silence detected - end of speech
            let totalDuration = Date().timeIntervalSince(speechStartTime ?? Date())
            Task { @MainActor in
                self.state = .listening
                AppLogger.shared.log("[Voice] 🔇 Speech END detected (silence: \(String(format: "%.1f", silenceDuration))s, total speech: \(String(format: "%.1f", totalDuration))s)", level: .info, category: "Voice")
                self.onSpeechEnd?()
            }
        }
    }
}

// MARK: - Error Types

enum VADError: LocalizedError {
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission denied. Please enable microphone access in Settings."
        }
    }
}
