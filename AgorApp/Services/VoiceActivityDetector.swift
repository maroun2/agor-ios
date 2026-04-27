import Foundation
import AVFoundation
import FluidAudio

@Observable
final class VoiceActivityDetector {
    enum State {
        case idle
        case listening
        case speechDetected
    }

    var state: State = .idle
    /// Speech probability from FluidAudio (0.0–1.0), drives AudioLevelBar.
    var currentAudioLevel: Float = 0.0
    /// Current FluidAudio threshold — drives AudioLevelBar threshold line.
    var energyThreshold: Float = 0.6

    // All tunable constants — read from audio/processing paths.
    @ObservationIgnored var config = VADConfig()

    // VAD sensitivity (0.0 low → 1.0 high)
    private(set) var sensitivityLevel: Float = 0.5

    // FluidAudio model
    @ObservationIgnored private var vadManager: VadManager?

    // Audio engine
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var inputNode: AVAudioInputNode?

    // Audio resampling: device rate (44.1/48kHz) → 16kHz mono Float32
    @ObservationIgnored private var audioConverter: AVAudioConverter?
    @ObservationIgnored private var targetFormat: AVAudioFormat?

    // Chunk accumulation: 1024-sample tap buffers → VadManager.chunkSize FluidAudio chunks
    @ObservationIgnored private var chunkBuffer: [Float] = []

    // AsyncStream bridge: audio tap (real-time) → async processing task
    @ObservationIgnored private var streamContinuation: AsyncStream<[Float]>.Continuation?
    @ObservationIgnored private var processingTask: Task<Void, Never>?

    // Silence debounce timer
    @ObservationIgnored private var silenceTimer: Timer?

    // Callbacks
    var onSpeechStart: (() -> Void)?
    var onSpeechEnd: (() -> Void)?
    var onCalibrationComplete: (() -> Void)?

    // MARK: - Model Initialization

    /// Download/load Silero VAD CoreML model (~2MB, runs on Neural Engine).
    /// Call once before startListening().
    func initializeModel() async throws {
        let threshold = config.threshold
        vadManager = try await VadManager(config: VadConfig(defaultThreshold: threshold))
        AppLogger.shared.log("[VAD] FluidAudio Silero model loaded (threshold=\(String(format: "%.2f", threshold)))", level: .info, category: "Voice")
    }

    // MARK: - Configuration

    func setSensitivity(_ sensitivity: Float) {
        sensitivityLevel = max(0.0, min(1.0, sensitivity))
        config.threshold = VADConfig.threshold(for: sensitivityLevel)
        energyThreshold = config.threshold
        AppLogger.shared.log(
            "[VAD] Sensitivity \(String(format: "%.2f", sensitivityLevel))"
            + " → threshold=\(String(format: "%.2f", config.threshold))",
            level: .debug, category: "Voice"
        )
    }

    // MARK: - Start / Stop

    func startListening() throws {
        guard state == .idle else { return }
        guard vadManager != nil else {
            throw VADError.modelNotLoaded
        }

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

        // Reset state
        chunkBuffer = []
        energyThreshold = config.threshold

        // Setup audio engine
        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }

        inputNode = engine.inputNode
        guard let input = inputNode else { return }

        let inputFormat = input.outputFormat(forBus: 0)

        // Setup resampler: device format → 16kHz mono Float32 (FluidAudio requirement)
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(VadManager.sampleRate),
            channels: 1,
            interleaved: false
        )!
        audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat!)

        // Create AsyncStream bridge: audio tap pushes chunks, processing task consumes
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        self.streamContinuation = continuation

        // Start FluidAudio streaming processing task
        startProcessingTask(stream: stream)

        // Install audio tap — resamples and accumulates chunks
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer)
        }

        try engine.start()
        state = .listening

        // No calibration needed — FluidAudio model is ready immediately
        Task { @MainActor in
            self.onCalibrationComplete?()
        }

        AppLogger.shared.log(
            "[VAD] FluidAudio streaming started"
            + " (threshold=\(String(format: "%.2f", config.threshold))"
            + ", silenceDur=\(String(format: "%.1f", config.silenceDuration))s)",
            level: .info, category: "Voice"
        )
    }

    /// No-op — FluidAudio needs no calibration. Kept for ContinuousVoiceService compat.
    func skipCalibration() {}

    func stopListening() {
        guard state != .idle else { return }

        cancelSilenceTimer()

        // Stop processing pipeline
        processingTask?.cancel()
        processingTask = nil
        streamContinuation?.finish()
        streamContinuation = nil

        // Stop audio engine
        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        inputNode = nil
        audioConverter = nil
        chunkBuffer = []

        state = .idle
        AppLogger.shared.log("[VAD] Stopped listening", level: .info, category: "Voice")
    }

    // MARK: - Audio Processing (Audio Thread → AsyncStream)

    /// Called on audio render thread. Resamples to 16kHz, accumulates chunks,
    /// yields 4096-sample arrays to the AsyncStream for FluidAudio processing.
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let converter = audioConverter, let targetFmt = targetFormat else { return }

        // Calculate output frame count for 16kHz
        let ratio = Double(VadManager.sampleRate) / buffer.format.sampleRate
        let frameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard frameCount > 0,
              let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: frameCount) else { return }

        // Resample — inputBlock provides source data exactly once
        var inputConsumed = false
        var convError: NSError?
        let status = converter.convert(to: convertedBuffer, error: &convError) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        guard status != .error,
              let floatData = convertedBuffer.floatChannelData?[0] else { return }

        // Copy resampled samples into accumulation buffer
        let samples = Array(UnsafeBufferPointer(start: floatData, count: Int(convertedBuffer.frameLength)))
        chunkBuffer.append(contentsOf: samples)

        // Yield complete 4096-sample chunks to processing task
        while chunkBuffer.count >= VadManager.chunkSize {
            let chunk = Array(chunkBuffer.prefix(VadManager.chunkSize))
            chunkBuffer.removeFirst(VadManager.chunkSize)
            streamContinuation?.yield(chunk)
        }
    }

    // MARK: - FluidAudio Streaming Task

    private func startProcessingTask(stream: AsyncStream<[Float]>) {
        guard let manager = vadManager else { return }

        processingTask = Task { [weak self] in
            var streamState = await manager.makeStreamState()

            for await chunk in stream {
                guard !Task.isCancelled else { break }
                guard let self else { break }

                do {
                    let result = try await manager.processStreamingChunk(
                        chunk,
                        state: streamState,
                        config: .default,
                        returnSeconds: true,
                        timeResolution: 2
                    )
                    streamState = result.state

                    // Update probability display
                    await MainActor.run {
                        self.currentAudioLevel = result.probability
                    }

                    // Handle speech events
                    if let event = result.event {
                        await MainActor.run {
                            self.handleVadEvent(event)
                        }
                    }
                } catch {
                    AppLogger.shared.log(
                        "[VAD] Streaming chunk error: \(error.localizedDescription)",
                        level: .error, category: "Voice"
                    )
                }
            }
        }
    }

    // MARK: - VAD Event Handling (MainActor)

    private func handleVadEvent(_ event: VadStreamEvent) {
        switch event.kind {
        case .speechStart:
            // Cancel any pending silence timer — speech resumed
            cancelSilenceTimer()

            if state == .listening {
                state = .speechDetected
                AppLogger.shared.log(
                    "[VAD] 🎤 Speech START (prob=\(String(format: "%.2f", currentAudioLevel)))",
                    level: .info, category: "Voice"
                )
                onSpeechStart?()
            }

        case .speechEnd:
            // Debounce: wait silenceDuration before propagating onSpeechEnd.
            // FluidAudio may fire speechEnd during brief inter-syllable pauses;
            // this prevents premature cutoff for conversational speech.
            if state == .speechDetected {
                startSilenceTimer()
            }
        }
    }

    // MARK: - Silence Debounce

    private func startSilenceTimer() {
        cancelSilenceTimer()
        let duration = config.silenceDuration
        DispatchQueue.main.async { [weak self] in
            self?.silenceTimer = Timer.scheduledTimer(
                withTimeInterval: duration,
                repeats: false
            ) { [weak self] _ in
                guard let self, self.state == .speechDetected else { return }
                self.state = .listening
                AppLogger.shared.log(
                    "[VAD] 🔇 Speech END (debounce=\(String(format: "%.1f", duration))s)",
                    level: .info, category: "Voice"
                )
                self.onSpeechEnd?()
            }
        }
        AppLogger.shared.log(
            "[VAD] ⏱️ Silence timer started (\(String(format: "%.1f", duration))s)",
            level: .debug, category: "Voice"
        )
    }

    private func cancelSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = nil
    }
}

// MARK: - Error Types

enum VADError: LocalizedError {
    case microphonePermissionDenied
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission denied. Please enable microphone access in Settings."
        case .modelNotLoaded:
            return "VAD model not loaded. Call initializeModel() first."
        }
    }
}
