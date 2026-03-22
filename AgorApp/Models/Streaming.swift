import Foundation

// MARK: - Streaming Message (in-flight accumulator)

struct StreamingMessage: Identifiable {
    let messageId: String
    let sessionId: String
    var taskId: String?
    let role: MessageRole = .assistant
    var content: String = ""
    var thinkingContent: String?
    let timestamp: String
    var isStreaming: Bool = true
    var isThinking: Bool = false
    var hasError: Bool = false
    var errorMessage: String?

    var id: String { messageId }
}

// MARK: - Streaming Events

struct StreamingStartEvent: Codable {
    let messageId: String
    let sessionId: String
    var taskId: String?
    let role: String?
    let timestamp: String?

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case sessionId = "session_id"
        case taskId = "task_id"
        case role, timestamp
    }
}

struct StreamingChunkEvent: Codable {
    let messageId: String
    let sessionId: String
    let chunk: String

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case sessionId = "session_id"
        case chunk
    }
}

struct StreamingEndEvent: Codable {
    let messageId: String
    let sessionId: String

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case sessionId = "session_id"
    }
}

struct StreamingErrorEvent: Codable {
    let messageId: String
    let sessionId: String
    let error: String

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case sessionId = "session_id"
        case error
    }
}

struct ThinkingStartEvent: Codable {
    let messageId: String
    let sessionId: String
    var taskId: String?
    let timestamp: String?

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case sessionId = "session_id"
        case taskId = "task_id"
        case timestamp
    }
}

struct ThinkingChunkEvent: Codable {
    let messageId: String
    let sessionId: String
    let chunk: String

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case sessionId = "session_id"
        case chunk
    }
}

struct ThinkingEndEvent: Codable {
    let messageId: String
    let sessionId: String

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case sessionId = "session_id"
    }
}
