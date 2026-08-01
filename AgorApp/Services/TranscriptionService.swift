import Foundation
import WhisperKit

@Observable
final class TranscriptionService {
    /// One Whisper model in memory for the whole app — voice mode and hold-to-talk
    /// dictation share it, and it can be preloaded at launch.
    static let shared = TranscriptionService()

    /// Set once the user has used any voice feature; gates the launch-time preload
    /// so users who never touch voice pay no memory/CPU cost.
    static let voiceUsedKey = "agor.voiceFeatureUsed"

    /// Preload the Whisper model in the background if the user has used voice before.
    static func preloadIfUsedBefore() {
        guard UserDefaults.standard.bool(forKey: voiceUsedKey) else { return }
        Task.detached(priority: .utility) {
            AppLogger.shared.log("[Voice] Preloading Whisper model at launch (voice used before)", level: .info, category: "Voice")
            try? await shared.initialize()
        }
    }

    static func markVoiceUsed() {
        UserDefaults.standard.set(true, forKey: voiceUsedKey)
    }

    enum State {
        case notInitialized
        case downloading(progress: Double)
        case warming          // CoreML model compilation after download
        case ready
        case transcribing
        case error(String)
    }

    var state: State = .notInitialized
    private var whisperKit: WhisperKit?
    private let modelName: String

    init(modelName: String = "openai_whisper-base.en") {
        self.modelName = modelName
    }

    // MARK: - Initialization

    @ObservationIgnored private var initTask: Task<Void, Error>?

    func initialize() async throws {
        // Dedup concurrent callers (launch preload racing voice-mode enable):
        // everyone awaits the same underlying load.
        if let initTask {
            return try await initTask.value
        }
        let task = Task { try await performInitialize() }
        initTask = task
        do {
            try await task.value
        } catch {
            initTask = nil  // allow retry after failure
            throw error
        }
    }

    private func performInitialize() async throws {
        guard case .notInitialized = state else { return }

        state = .downloading(progress: 0.0)

        do {
            whisperKit = try await WhisperKit(model: modelName, prewarm: false)
            AppLogger.shared.log("[Voice] WhisperKit loaded model: \(modelName)", level: .info, category: "Voice")

            // Prewarm separately so we can show "Warming up..." state
            state = .warming
            AppLogger.shared.log("[Voice] Prewarming CoreML model (first-run compilation)...", level: .info, category: "Voice")
            try await whisperKit?.prewarmModels()
            state = .ready
            AppLogger.shared.log("[Voice] WhisperKit ready", level: .info, category: "Voice")
        } catch {
            let errorMsg = "Failed to initialize WhisperKit: \(error.localizedDescription)"
            state = .error(errorMsg)
            AppLogger.shared.log("[Voice] \(errorMsg)", level: .error, category: "Voice")
            throw error
        }
    }

    // MARK: - Transcription

    func transcribe(audioPath: String) async throws -> String {
        if whisperKit == nil {
            try await initialize()
        }
        guard let whisperKit else {
            throw TranscriptionError.notInitialized
        }

        state = .transcribing
        let startTime = Date()
        AppLogger.shared.log("[Voice] 📝 Starting transcription for: \(audioPath)", level: .info, category: "Voice")

        do {
            let results = try await whisperKit.transcribe(audioPath: audioPath)
            state = .ready

            let text = results.map(\.text).joined(separator: " ")
            let duration = Date().timeIntervalSince(startTime)
            AppLogger.shared.log("[Voice] ✅ Transcription complete in \(String(format: "%.1f", duration))s: \"\(text)\" (\(text.count) chars)", level: .info, category: "Voice")
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            let errorMsg = "Transcription failed: \(error.localizedDescription)"
            state = .error(errorMsg)
            AppLogger.shared.log("[Voice] ❌ \(errorMsg)", level: .error, category: "Voice")
            throw error
        }
    }

    func transcribe(audioURL: URL) async throws -> String {
        return try await transcribe(audioPath: audioURL.path)
    }
}

// MARK: - Error Types

enum TranscriptionError: LocalizedError {
    case notInitialized
    case invalidAudioFile
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Transcription service not initialized"
        case .invalidAudioFile:
            return "Invalid audio file"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        }
    }
}
