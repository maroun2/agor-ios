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
    private var energyThreshold: Float = 0.02  // Speech start threshold
    private var silenceThreshold: Float = 0.01  // Silence threshold
    private let silenceDuration: TimeInterval = 1.5  // Seconds of silence to detect end

    private var lastSoundTime: Date = Date()
    private var speechStartTime: Date?
    private var silenceCheckTimer: Timer?

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

        // Setup audio session
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
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
        guard let floatData = buffer.floatChannelData?[0] else { return }
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

        // Speech detection logic
        if state == .listening && rms > energyThreshold {
            // Speech detected!
            Task { @MainActor in
                self.speechStartTime = Date()
                self.state = .speechDetected
                self.onSpeechStart?()
                AppLogger.shared.log("[Voice] Speech detected (RMS: \(rms))", level: .debug, category: "Voice")
            }
        }

        // Update last sound time if audio is above silence threshold
        if rms > silenceThreshold {
            lastSoundTime = Date()
        }
    }

    private func startSilenceCheckTimer() {
        silenceCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkForSilence()
        }
    }

    private func checkForSilence() {
        guard state == .speechDetected else { return }

        let silenceDuration = Date().timeIntervalSince(lastSoundTime)
        if silenceDuration >= self.silenceDuration {
            // Silence detected - end of speech
            Task { @MainActor in
                self.state = .listening
                self.onSpeechEnd?()
                AppLogger.shared.log("[Voice] Silence detected, speech ended", level: .debug, category: "Voice")
            }
        }
    }
}
