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

    // All tunable constants — change at any time, takes effect next audio frame.
    // @ObservationIgnored: config is read on the audio thread and must not be
    // wrapped by the @Observable macro's MainActor-locked access tracking.
    @ObservationIgnored var config = VADConfig()

    // VAD sensitivity (0.0 low → 1.0 high) — drives startMultiplier via config
    private(set) var sensitivityLevel: Float = 0.5

    // Derived multipliers
    private var startMultiplier: Float { config.startMultiplier(for: sensitivityLevel) }
    private var endMultiplier: Float { startMultiplier * config.hysteresisRatio }

    // --- Audio-thread-only state ---
    // @ObservationIgnored prevents race with @Observable's MainActor-locked access tracking

    @ObservationIgnored private var smoothedEnergy: Float = 0.0
    @ObservationIgnored private var noiseFloor: Float = 0.001
    @ObservationIgnored private var calibrationFramesRemaining: Int = 0

    // M-of-N confirmation: ring buffer of recent above-threshold results
    private static let ringBufferSize = 30
    @ObservationIgnored private var recentAbove: [Bool] = Array(repeating: false, count: ringBufferSize)
    @ObservationIgnored private var frameIndex: Int = 0

    // Noise floor freeze: prevent floor rise for N frames after any above-threshold frame.
    // Breaks the feedback loop where the floor chases speech during brief inter-syllable dips.
    @ObservationIgnored private var freezeFramesRemaining: Int = 0

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
        AppLogger.shared.log(
            "[VAD] Sensitivity \(String(format: "%.2f", sensitivityLevel)) "
            + "→ startMult=\(String(format: "%.2f", startMultiplier)) "
            + "endMult=\(String(format: "%.2f", endMultiplier))",
            level: .debug, category: "Voice"
        )
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

        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers]
        )
        try session.setActive(true)

        // Reset adaptive state so we calibrate fresh on each start
        smoothedEnergy = 0.0
        noiseFloor = 0.001
        recentAbove = Array(repeating: false, count: Self.ringBufferSize)
        frameIndex = 0
        freezeFramesRemaining = 0
        calibrationFramesRemaining = config.calibrationFrameCount
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
        let cfgLog = "[VAD] Started"
            + " emaAtk=\(config.emaAttackAlpha)"
            + " emaRel=\(config.emaReleaseAlpha)"
            + " confirm=\(config.confirmationRequired)of\(config.confirmationWindow)"
            + " freeze=\(config.noiseFloorFreezeFrames)fr"
            + " riseAlpha=\(config.noiseFloorRiseAlpha)"
            + " fallAlpha=\(config.noiseFloorFallAlpha)"
            + " maxFloor=\(config.maxNoiseFloor)"
            + " hysteresis=\(config.hysteresisRatio)"
            + " suppressGate=\(config.suppressRiseGateMultiplier)×floor"
            + " silenceDur=\(config.silenceDuration)s"
        AppLogger.shared.log(cfgLog, level: .info, category: "Voice")
    }

    /// Call immediately after startListening() when resuming — noise floor already calibrated.
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
        let emaAlpha = rms > smoothedEnergy ? config.emaAttackAlpha : config.emaReleaseAlpha
        smoothedEnergy = emaAlpha * rms + (1.0 - emaAlpha) * smoothedEnergy

        let startThreshold = noiseFloor * startMultiplier
        let endThreshold   = noiseFloor * endMultiplier

        // 3. Noise floor freeze countdown
        if freezeFramesRemaining > 0 {
            freezeFramesRemaining -= 1
        }

        // 4. Adaptive noise floor
        if state == .listening {
            let isCalibrating = calibrationFramesRemaining > 0
            let riseAlpha = isCalibrating ? config.noiseFloorCalibrationAlpha : config.noiseFloorRiseAlpha

            // ── Suppress-rise gate ──────────────────────────────────────────
            // Gate = noiseFloor × suppressRiseGateMultiplier (default 2.0).
            // Any energy above the gate freezes the floor — it could be speech.
            // Also suppress while freeze timer is active (prevents the floor from
            // chasing speech during brief inter-syllable dips).
            // Exception: during calibration always allow rise so the floor can
            // converge from 0.001 to actual ambient before speech detection opens.
            let suppressGate = noiseFloor * config.suppressRiseGateMultiplier
            let suppressRise = !isCalibrating &&
                (smoothedEnergy >= suppressGate || freezeFramesRemaining > 0)

            if smoothedEnergy > noiseFloor && !suppressRise {
                // Rise: floor tracks ambient noise upward
                noiseFloor = riseAlpha * smoothedEnergy + (1.0 - riseAlpha) * noiseFloor
            } else if smoothedEnergy < noiseFloor {
                // Fall: floor drops when room gets quieter
                noiseFloor = config.noiseFloorFallAlpha * smoothedEnergy
                    + (1.0 - config.noiseFloorFallAlpha) * noiseFloor
            }
            // else: energy >= floor but rise suppressed → floor stays flat
            // (Previously this fell through to the fall branch, which inadvertently
            //  raised the floor via EMA when energy > floor and suppress was active.)
        } else if state == .speechDetected {
            // During recording: only fall, never rise.
            // Prevents speech from inflating the threshold mid-utterance.
            if smoothedEnergy < noiseFloor {
                noiseFloor = config.noiseFloorFallAlpha * smoothedEnergy
                    + (1.0 - config.noiseFloorFallAlpha) * noiseFloor
            }
        }
        noiseFloor = max(noiseFloor, 0.0005)
        noiseFloor = min(noiseFloor, config.maxNoiseFloor)

        // Publish to MainActor — energyThreshold drives the live threshold line in the waveform
        Task { @MainActor in
            self.currentAudioLevel = self.smoothedEnergy
            self.energyThreshold = self.noiseFloor * self.startMultiplier
        }

        bufferCount += 1
        if bufferCount % 100 == 0 {
            AppLogger.shared.log(
                "[VAD] 📊 smoothed=\(String(format: "%.4f", smoothedEnergy)) "
                + "noise=\(String(format: "%.4f", noiseFloor)) "
                + "start>\(String(format: "%.4f", startThreshold)) "
                + "end>\(String(format: "%.4f", endThreshold)) "
                + "freeze=\(freezeFramesRemaining) cal=\(calibrationFramesRemaining) state=\(state)",
                level: .info, category: "Voice"
            )
        }

        // 5. M-of-N speech confirmation
        //    Instead of requiring N consecutive frames above threshold (which resets
        //    on any brief dip), require M frames above threshold within a window of N.
        //    This tolerates natural speech variability and inter-syllable pauses.
        if state == .listening {
            if calibrationFramesRemaining > 0 {
                calibrationFramesRemaining -= 1
                recentAbove[frameIndex % Self.ringBufferSize] = false
                frameIndex += 1
            } else {
                let isAbove = smoothedEnergy > startThreshold
                recentAbove[frameIndex % Self.ringBufferSize] = isAbove
                frameIndex += 1

                // Freeze floor whenever a frame is above threshold — prevents the
                // noise floor from chasing speech energy if the next frame dips briefly
                if isAbove {
                    freezeFramesRemaining = config.noiseFloorFreezeFrames
                }

                // Count hits in recent window
                let window = min(config.confirmationWindow, Self.ringBufferSize, frameIndex)
                var hits = 0
                for i in (frameIndex - window)..<frameIndex {
                    if recentAbove[i % Self.ringBufferSize] { hits += 1 }
                }

                if hits >= config.confirmationRequired {
                    // Reset ring for next detection
                    recentAbove = Array(repeating: false, count: Self.ringBufferSize)
                    frameIndex = 0
                    freezeFramesRemaining = 0

                    Task { @MainActor in
                        self.speechStartTime = Date()
                        self.state = .speechDetected
                        AppLogger.shared.log(
                            "[VAD] 🎤 Speech START (\(hits)/\(window) frames"
                            + " smoothed=\(String(format: "%.4f", self.smoothedEnergy))"
                            + " > threshold=\(String(format: "%.4f", startThreshold))"
                            + " noise=\(String(format: "%.4f", self.noiseFloor)))",
                            level: .info, category: "Voice"
                        )
                        self.onSpeechStart?()
                    }
                }
            }
        }

        // 6. Update silence tracking
        if smoothedEnergy > endThreshold {
            lastSoundTime = Date()
        }

        if state == .speechDetected {
            let silenceDur = Date().timeIntervalSince(lastSoundTime)
            AppLogger.shared.log(
                "[VAD] 🎙️ Recording: smoothed=\(String(format: "%.4f", smoothedEnergy))"
                + " silence=\(String(format: "%.1f", silenceDur))s"
                + " endThresh=\(String(format: "%.4f", endThreshold))",
                level: .debug, category: "Voice"
            )
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
        if silenceElapsed >= config.silenceDuration {
            let totalDuration = Date().timeIntervalSince(speechStartTime ?? Date())
            Task { @MainActor in
                self.state = .listening
                AppLogger.shared.log(
                    "[VAD] 🔇 Speech END (silence=\(String(format: "%.1f", silenceElapsed))s"
                    + " total=\(String(format: "%.1f", totalDuration))s)",
                    level: .info, category: "Voice"
                )
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
