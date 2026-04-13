import Foundation
import WhisperKit

@Observable
final class TranscriptionService {
    enum State {
        case notInitialized
        case downloading(progress: Double)
        case ready
        case transcribing
        case error(String)
    }

    var state: State = .notInitialized
    private var whisperKit: WhisperKit?
    private let modelName: String

    init(modelName: String = "base-en") {
        self.modelName = modelName
    }

    // MARK: - Initialization

    func initialize() async throws {
        guard case .notInitialized = state else { return }

        state = .downloading(progress: 0.0)

        do {
            whisperKit = try await WhisperKit(model: modelName)
            state = .ready
            AppLogger.shared.log("[Voice] WhisperKit initialized with model: \(modelName)", level: .info, category: "Voice")
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
