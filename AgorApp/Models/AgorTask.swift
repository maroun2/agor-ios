import Foundation

// MARK: - Task Status

enum TaskStatus: String, Codable {
    case created
    case running
    case stopping
    case awaitingPermission = "awaiting_permission"
    case awaitingInput = "awaiting_input"
    case timedOut = "timed_out"
    case completed
    case failed
    case stopped

    var displayLabel: String {
        switch self {
        case .created: "Created"
        case .running: "Running"
        case .stopping: "Stopping"
        case .awaitingPermission: "Awaiting Permission"
        case .awaitingInput: "Awaiting Input"
        case .timedOut: "Timed Out"
        case .completed: "Completed"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }
}

// MARK: - Task Git State

struct TaskGitState: Codable {
    let refAtStart: String
    let shaAtStart: String
    var shaAtEnd: String?
    var commitMessage: String?

    enum CodingKeys: String, CodingKey {
        case refAtStart = "ref_at_start"
        case shaAtStart = "sha_at_start"
        case shaAtEnd = "sha_at_end"
        case commitMessage = "commit_message"
    }
}

// MARK: - Token Usage

struct TokenUsage: Codable {
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    var cacheReadTokens: Int?
    var cacheCreationTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "inputTokens"
        case outputTokens = "outputTokens"
        case totalTokens = "totalTokens"
        case cacheReadTokens = "cacheReadTokens"
        case cacheCreationTokens = "cacheCreationTokens"
    }
}

struct NormalizedSDKResponse: Codable {
    var tokenUsage: TokenUsage?
    var contextWindowLimit: Int?
    var costUsd: Double?

    enum CodingKeys: String, CodingKey {
        case tokenUsage = "tokenUsage"
        case contextWindowLimit = "contextWindowLimit"
        case costUsd = "costUsd"
    }
}

// MARK: - AgorTask

struct AgorTask: Codable, Identifiable {
    let taskId: String
    let sessionId: String
    let createdBy: String
    let fullPrompt: String
    var description: String?
    var status: TaskStatus
    var firstMessageIndex: Int?
    var lastMessageIndex: Int?
    var toolUseCount: Int?
    var gitState: TaskGitState?
    var durationMs: Int?
    var model: String?
    var normalizedSdkResponse: NormalizedSDKResponse?
    let createdAt: String
    var startedAt: String?
    var completedAt: String?

    var id: String { taskId }

    var promptPreview: String {
        let text = fullPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 120 {
            return String(text.prefix(120)) + "..."
        }
        return text
    }

    var formattedDuration: String? {
        guard let ms = durationMs else { return nil }
        let seconds = ms / 1000
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remaining = seconds % 60
        return "\(minutes)m \(remaining)s"
    }

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
        case sessionId = "session_id"
        case createdBy = "created_by"
        case fullPrompt = "full_prompt"
        case description
        case status
        case firstMessageIndex = "first_message_index"
        case lastMessageIndex = "last_message_index"
        case toolUseCount = "tool_use_count"
        case gitState = "git_state"
        case durationMs = "duration_ms"
        case model
        case normalizedSdkResponse = "normalized_sdk_response"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}
