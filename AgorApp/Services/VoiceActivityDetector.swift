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
    // Observable properties — updated on MainActor, safe for SwiftUI binding
    var currentAudioLevel: Float = 0.0
    var energyThreshold: Float = 0.0   // Speech-start threshold (live, for waveform line)

    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?

    // VAD configuration — base sensitivity (0.0 low → 1.0 high)
    private(set) var sensitivityLevel: Float = 0.5
    private let silenceDuration: TimeInterval = 1.5  // Seconds of silence to end speech

    // --- Moving-average / adaptive-threshold state (audio-thread only) ---
    // Marked @ObservationIgnored so mutations on the audio tap thread don't race
    // with @Observable's MainActor-locked access tracking.

    // Exponential moving average of RMS (smooths out transients).
    // α controls responsiveness: higher α = faster tracking.
    @ObservationIgnored private var smoothedEnergy: Float = 0.0
    private let emaAlpha: Float = 0.15  // ~7 frame lag at 48 kHz / 1024 buf ≈ 47 fps

    // Adaptive noise floor: tracks background noise during silence.
    // Rises quickly (burst) and falls at a reasonable rate when room goes quiet.
    @ObservationIgnored private var noiseFloor: Float = 0.001
    private let noiseFloorRiseAlpha: Float = 0.05   // Fast rise (~0.3s to track louder background)
    private let noiseFloorFallAlpha: Float = 0.008  // Faster fall — halves in ~1.8s when room quietens
    // Hard cap: ensures startThreshold never exceeds typical speech (0.03–0.1 RMS).
    // Without this, loud sustained background raises noiseFloor until VAD can never fire.
    private let maxNoiseFloor: Float = 0.010        // startThreshold cap = 0.010 × 2.75 = 0.0275

    // Speech-start confirmation: require N consecutive frames above threshold
    // to avoid false triggers from short transients (keyboard taps, clicks).
    @ObservationIgnored private var consecutiveAboveThreshold: Int = 0
    private let confirmationFrames: Int = 4  // ~80ms at 47 fps

    // Speech-start threshold = noiseFloor × startMultiplier
    // Speech-end threshold   = noiseFloor × endMultiplier
    // Multipliers are adjusted by sensitivityLevel.
    private var startMultiplier: Float { 3.5 - sensitivityLevel * 1.5 }  // 3.5 (low) → 2.0 (high)
    private var endMultiplier: Float   { 2.0 - sensitivityLevel * 0.8 }  // 2.0 (low) → 1.2 (high)

    private var lastSoundTime: Date = Date()
    private var speechStartTime: Date?
    private var silenceCheckTimer: Timer?
    private var bufferCount: Int = 0

    // Callbacks
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?

    // MARK: - Configuration

    func setSensitivity(_ sensitivity: Float) {
        sensitivityLevel = max(0.0, min(1.0, sensitivity))
        AppLogger.shared.log("[VAD] Sensitivity set to \(String(format: "%.2f", sensitivityLevel)) → startMult=\(String(format: "%.2f", startMultiplier)) endMult=\(String(format: "%.2f", endMultiplier))", level: .debug, category: "Voice")
    }

    // MARK: - Start/Stop

    func startListening() throws {
        guard state == .idle else { return }

        let session = AVAudioSession.sharedInstance()

        switch session.recordPermission {
        case .denied:
            throw VADError.microphonePermissionDenied
        case .undetermined:
            var granted = false
            let semaphore = DispatchSemaphore(value: 0)
            session.requestRecordPermission { allowed in
                granted = allowed
                semaphore.signal()
            }
            semaphore.wait()
            if !granted { throw VADError.microphonePermissionDenied }
        case .granted:
            break
        @unknown default:
            break
        }

        // .mixWithOthers lets AVAudioEngine/AVAudioPlayer play tones alongside the active recorder.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        try session.setActive(true)

        // Reset adaptive state so we calibrate to the new room on each start
        smoothedEnergy = 0.0
        noiseFloor = 0.001
        consecutiveAboveThreshold = 0
        energyThreshold = noiseFloor * startMultiplier

        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        inputNode = engine.inputNode
        guard let input = inputNode else { return }

        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        try engine.start()
        state = .listening

        startSilenceCheckTimer()
        AppLogger.shared.log("[VAD] Started listening (adaptive threshold, EMA smoothing)", level: .info, category: "Voice")
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
        AppLogger.shared.log("[VAD] Stopped listening", level: .info, category: "Voice")
    }

    // MARK: - Audio Processing

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)

        // 1. Calculate RMS for this frame
        var sum: Float = 0
        for i in 0..<frameLength {
            sum += floatData[i] * floatData[i]
        }
        let rms = sqrt(sum / Float(frameLength))

        // 2. Exponential moving average — smooth out transients
        smoothedEnergy = emaAlpha * rms + (1.0 - emaAlpha) * smoothedEnergy

        // 3. Update adaptive noise floor (only during silence, not while speech is active)
        if state == .listening {
            if smoothedEnergy > noiseFloor {
                noiseFloor = noiseFloorRiseAlpha * smoothedEnergy + (1.0 - noiseFloorRiseAlpha) * noiseFloor
            } else {
                noiseFloor = noiseFloorFallAlpha * smoothedEnergy + (1.0 - noiseFloorFallAlpha) * noiseFloor
            }
            // Clamp: min keeps threshold meaningful in dead-quiet rooms,
            // max prevents loud background from driving threshold above speech level.
            noiseFloor = max(noiseFloor, 0.0005)
            noiseFloor = min(noiseFloor, maxNoiseFloor)
        }

        let startThreshold = noiseFloor * startMultiplier
        let endThreshold   = noiseFloor * endMultiplier

        // Publish to MainActor — energyThreshold drives the live threshold line in the waveform
        let publishedThreshold = startThreshold
        Task { @MainActor in
            self.currentAudioLevel = self.smoothedEnergy
            self.energyThreshold = publishedThreshold
        }

        bufferCount += 1
        if bufferCount % 100 == 0 {
            AppLogger.shared.log("[VAD] 📊 smoothed=\(String(format: "%.4f", smoothedEnergy)) noise=\(String(format: "%.4f", noiseFloor)) start>\(String(format: "%.4f", startThreshold)) end>\(String(format: "%.4f", endThreshold)) state=\(state)", level: .info, category: "Voice")
        }

        // 4. Speech-start detection with multi-frame confirmation
        if state == .listening {
            if smoothedEnergy > startThreshold {
                consecutiveAboveThreshold += 1
                if consecutiveAboveThreshold >= confirmationFrames {
                    consecutiveAboveThreshold = 0
                    Task { @MainActor in
                        self.speechStartTime = Date()
                        self.state = .speechDetected
                        AppLogger.shared.log("[VAD] 🎤 Speech START (smoothed=\(String(format: "%.4f", self.smoothedEnergy)) > threshold=\(String(format: "%.4f", startThreshold)), noise=\(String(format: "%.4f", self.noiseFloor)))", level: .info, category: "Voice")
                        self.onSpeechStart?()
                    }
                }
            } else {
                consecutiveAboveThreshold = 0
            }
        }

        // 5. Update last-sound time for silence duration tracking
        if smoothedEnergy > endThreshold {
            lastSoundTime = Date()
        }

        if state == .speechDetected {
            let silenceDur = Date().timeIntervalSince(lastSoundTime)
            AppLogger.shared.log("[VAD] 🎙️ Recording: smoothed=\(String(format: "%.4f", smoothedEnergy)) silence=\(String(format: "%.1f", silenceDur))s endThresh=\(String(format: "%.4f", endThreshold))", level: .debug, category: "Voice")
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

        let silenceElapsed = Date().timeIntervalSince(lastSoundTime)
        if silenceElapsed >= silenceDuration {
            let totalDuration = Date().timeIntervalSince(speechStartTime ?? Date())
            Task { @MainActor in
                self.state = .listening
                AppLogger.shared.log("[VAD] 🔇 Speech END (silence=\(String(format: "%.1f", silenceElapsed))s, total=\(String(format: "%.1f", totalDuration))s)", level: .info, category: "Voice")
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
