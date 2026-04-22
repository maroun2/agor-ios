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
    private let silenceDuration: TimeInterval = 3.0  // Seconds of silence to end speech

    // --- Moving-average / adaptive-threshold state (audio-thread only) ---
    // Marked @ObservationIgnored so mutations on the audio tap thread don't race
    // with @Observable's MainActor-locked access tracking.

    // Asymmetric EMA: fast attack tracks speech onset quickly; slow release keeps the
    // level stable during speech so the end-threshold comparison is smooth.
    // Attack  α=0.30 → ~3 frames (~65ms) to rise  — catches speech onset fast
    // Release α=0.08 → ~12 frames (~255ms) to fall — prevents choppy level readout
    @ObservationIgnored private var smoothedEnergy: Float = 0.0
    private let emaAttackAlpha: Float  = 0.30
    private let emaReleaseAlpha: Float = 0.08

    // Adaptive noise floor: tracks background noise during silence.
    // Three distinct alphas:
    //   calibration — fast convergence during startup so the floor adapts to the room
    //                 before speech detection opens (~0.5s to reach 95% of ambient)
    //   rise        — gradual during normal listening to avoid reacting to brief bursts
    //   fall        — moderate so the threshold drops when the room quietens
    @ObservationIgnored private var noiseFloor: Float = 0.001
    private let noiseFloorCalibrationAlpha: Float = 0.15  // Fast: used for first ~1.3s
    private let noiseFloorRiseAlpha: Float         = 0.02  // Gradual rise (~2s to reach ambient)
    private let noiseFloorFallAlpha: Float         = 0.008 // Halves in ~1.8s when room quietens
    // Hard cap: prevents loud sustained background from raising noiseFloor above speech level.
    private let maxNoiseFloor: Float               = 0.010 // → startThreshold cap ≈ 0.027 RMS

    // Calibration: suppress speech detection while the noise floor converges.
    @ObservationIgnored private var calibrationFramesRemaining: Int = 0
    private let calibrationFrames: Int = 60  // ~1.3s at 47 fps

    // Speech-start confirmation: industry standard ≥ 250ms of continuous speech before
    // triggering. Filters out keyboard clicks, breath sounds, and short transients.
    @ObservationIgnored private var consecutiveAboveThreshold: Int = 0
    private let confirmationFrames: Int = 12  // ~250ms at 47 fps

    // Speech-start threshold = noiseFloor × startMultiplier
    // Speech-end threshold   = noiseFloor × startMultiplier × hysteresisRatio
    //
    // Using a fixed hysteresisRatio (rather than independent end multiplier) keeps the
    // gap proportional across all sensitivity levels — matches industry practice.
    // Ratio 0.65 puts end at 65% of start (industry range: 0.60–0.75).
    private var startMultiplier: Float { 3.5 - sensitivityLevel * 1.5 }  // 3.5 (low) → 2.0 (high)
    private let hysteresisRatio: Float = 0.65
    private var endMultiplier: Float { startMultiplier * hysteresisRatio }

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
        calibrationFramesRemaining = calibrationFrames
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
        AppLogger.shared.log("[VAD] Started listening — asymmetric EMA, 250ms confirmation, adaptive floor", level: .info, category: "Voice")
    }

    /// Call immediately after startListening() when resuming — noise floor is already
    /// calibrated from the previous session, no need to re-suppress speech detection.
    func skipCalibration() {
        calibrationFramesRemaining = 0
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

        // 1. RMS for this frame
        var sum: Float = 0
        for i in 0..<frameLength {
            sum += floatData[i] * floatData[i]
        }
        let rms = sqrt(sum / Float(frameLength))

        // 2. Asymmetric EMA: fast attack / slow release
        let emaAlpha = rms > smoothedEnergy ? emaAttackAlpha : emaReleaseAlpha
        smoothedEnergy = emaAlpha * rms + (1.0 - emaAlpha) * smoothedEnergy

        // 3. Adaptive noise floor
        if state == .listening {
            // Use faster alpha during calibration so floor converges to room level quickly.
            let riseAlpha = calibrationFramesRemaining > 0 ? noiseFloorCalibrationAlpha : noiseFloorRiseAlpha
            if smoothedEnergy > noiseFloor {
                noiseFloor = riseAlpha * smoothedEnergy + (1.0 - riseAlpha) * noiseFloor
            } else {
                noiseFloor = noiseFloorFallAlpha * smoothedEnergy + (1.0 - noiseFloorFallAlpha) * noiseFloor
            }
        } else if state == .speechDetected {
            // During recording: only let floor fall, never rise.
            // Prevents speech itself from inflating the threshold mid-utterance.
            if smoothedEnergy < noiseFloor {
                noiseFloor = noiseFloorFallAlpha * smoothedEnergy + (1.0 - noiseFloorFallAlpha) * noiseFloor
            }
        }
        noiseFloor = max(noiseFloor, 0.0005)
        noiseFloor = min(noiseFloor, maxNoiseFloor)

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
            AppLogger.shared.log("[VAD] 📊 smoothed=\(String(format: "%.4f", smoothedEnergy)) noise=\(String(format: "%.4f", noiseFloor)) start>\(String(format: "%.4f", startThreshold)) end>\(String(format: "%.4f", endThreshold)) cal=\(calibrationFramesRemaining) state=\(state)", level: .info, category: "Voice")
        }

        // 4. Speech-start: require ~250ms of continuous speech before triggering
        if state == .listening {
            if calibrationFramesRemaining > 0 {
                calibrationFramesRemaining -= 1
                consecutiveAboveThreshold = 0
            } else if smoothedEnergy > startThreshold {
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

        // 5. Update silence tracking — end threshold sits at hysteresisRatio below start
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
