import Foundation
import WhisperKit

@Observable
final class TranscriptionService {
    /// One Whisper model in memory for the whole app — voice mode and hold-to-talk
    /// dictation share it, and it can be preloaded at launch.
    static let shared = TranscriptionService()

    /// Preload the Whisper model in the background at launch so voice mode starts
    /// instantly instead of downloading/warming on first use.
    static func preload() {
        Task.detached(priority: .utility) {
            AppLogger.shared.log("[Voice] Preloading Whisper model at launch", level: .info, category: "Voice")
            try? await shared.initialize()
        }
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

    /// Idempotent, retry-safe model load. Success is defined by `whisperKit != nil`,
    /// never by `state` — a previous failed attempt (`.error`) must NOT make later
    /// calls return "success" without a loaded model, or every transcription in the
    /// session throws and voice recordings get silently dropped.
    func initialize() async throws {
        // Await an in-flight load if one exists (launch preload racing voice enable)
        if let task = initTask {
            try? await task.value
            if whisperKit != nil { return }
            initTask = nil  // previous attempt failed — retry below
        }
        if whisperKit != nil { return }

        let task = Task { try await performInitialize() }
        initTask = task
        do {
            try await task.value
        } catch {
            initTask = nil  // allow retry on next call
            throw error
        }
    }

    private func performInitialize() async throws {
        if whisperKit != nil {
            state = .ready
            return
        }

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
