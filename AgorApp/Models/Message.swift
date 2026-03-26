import Foundation

// MARK: - Message Role

enum MessageRole: String, Codable {
    case user
    case assistant
    case system
}

// MARK: - Message Type

enum MessageType: String, Codable {
    case user
    case assistant
    case system
    case fileHistorySnapshot = "file-history-snapshot"
    case permissionRequest = "permission_request"
    case inputRequest = "input_request"
}

// MARK: - Content Block

enum ContentBlock: Codable, Identifiable {
    case text(TextContent)
    case toolUse(ToolUseContent)
    case toolResult(ToolResultContent)
    case thinking(ThinkingContent)
    case unknown(type: String)

    var id: String {
        switch self {
        case .text(let c): "text-\(c.text.hashValue)"
        case .toolUse(let c): "tool-\(c.id)"
        case .toolResult(let c): "result-\(c.toolUseId)"
        case .thinking(let c): "thinking-\(c.thinking.hashValue)"
        case .unknown(let type): "unknown-\(type)"
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            self = .text(try TextContent(from: decoder))
        case "tool_use":
            self = .toolUse(try ToolUseContent(from: decoder))
        case "tool_result":
            self = .toolResult(try ToolResultContent(from: decoder))
        case "thinking":
            self = .thinking(try ThinkingContent(from: decoder))
        default:
            self = .unknown(type: type)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let c): try c.encode(to: encoder)
        case .toolUse(let c): try c.encode(to: encoder)
        case .toolResult(let c): try c.encode(to: encoder)
        case .thinking(let c): try c.encode(to: encoder)
        case .unknown: break
        }
    }
}

// MARK: - Text Content

struct TextContent: Codable {
    let type: String
    let text: String

    init(type: String = "text", text: String) {
        self.type = type
        self.text = text
    }
}

// MARK: - Tool Use Content

struct ToolUseContent: Codable {
    let type: String
    let id: String
    let name: String
    let input: [String: AnyCodable]

    init(type: String = "tool_use", id: String, name: String, input: [String: AnyCodable]) {
        self.type = type
        self.id = id
        self.name = name
        self.input = input
    }

    var inputSummary: String {
        if let command = input["command"]?.stringValue {
            return command.count > 100 ? String(command.prefix(100)) + "..." : command
        }
        if let filePath = input["file_path"]?.stringValue ?? input["path"]?.stringValue {
            return filePath
        }
        let keys = input.keys.sorted().joined(separator: ", ")
        return keys.isEmpty ? "(no input)" : "{\(keys)}"
    }
}

// MARK: - Tool Result Content

struct ToolResultContent: Codable {
    let type: String
    let toolUseId: String
    let content: ToolResultValue?
    let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
    }
}

enum ToolResultValue: Codable {
    case string(String)
    case blocks([ToolResultBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let blocks = try? container.decode([ToolResultBlock].self) {
            self = .blocks(blocks)
        } else {
            self = .string("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .blocks(let b): try container.encode(b)
        }
    }

    var textPreview: String {
        switch self {
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > 200 ? String(trimmed.prefix(200)) + "..." : trimmed
        case .blocks(let blocks):
            let text = blocks.compactMap { $0.text }.joined(separator: "\n")
            return text.count > 200 ? String(text.prefix(200)) + "..." : text
        }
    }
}

struct ToolResultBlock: Codable {
    let type: String?
    let text: String?
}

// MARK: - Thinking Content

struct ThinkingContent: Codable {
    let type: String
    let thinking: String?  // nil for redacted blocks (only `signature` present)

    init(type: String = "thinking", thinking: String? = nil) {
        self.type = type
        self.thinking = thinking
    }
}

// MARK: - Message Content (polymorphic)

enum MessageContent {
    case text(String)
    case blocks([ContentBlock])
    case permissionRequest(PermissionRequestContent)
    case inputRequest(InputRequestContent)
}

// MARK: - Message Metadata

struct MessageMetadata: Codable {
    var model: String?
    var tokens: MessageTokens?
    var originalId: String?
    var parentId: String?
    var isMeta: Bool?
    var source: String?

    enum CodingKeys: String, CodingKey {
        case model, tokens, source
        case originalId = "original_id"
        case parentId = "parent_id"
        case isMeta = "is_meta"
    }
}

struct MessageTokens: Codable {
    let input: Int
    let output: Int
}

// MARK: - Message

struct Message: Identifiable {
    let messageId: String
    let sessionId: String
    var taskId: String?
    let type: MessageType
    let role: MessageRole
    let index: Int
    let timestamp: String
    let contentPreview: String
    let content: MessageContent
    var toolUses: [ToolUse]?
    var parentToolUseId: String?
    var status: String?
    var metadata: MessageMetadata?

    var id: String { messageId }

    var isPermissionRequest: Bool { type == .permissionRequest }
    var isInputRequest: Bool { type == .inputRequest }
}

struct ToolUse: Codable {
    let id: String
    let name: String
    let input: [String: AnyCodable]
}

// MARK: - Message Codable (custom decoding)

extension Message: Codable {
    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case sessionId = "session_id"
        case taskId = "task_id"
        case type, role, index, timestamp
        case contentPreview = "content_preview"
        case content
        case toolUses = "tool_uses"
        case parentToolUseId = "parent_tool_use_id"
        case status, metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        messageId = try container.decode(String.self, forKey: .messageId)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        taskId = try container.decodeIfPresent(String.self, forKey: .taskId)
        type = try container.decode(MessageType.self, forKey: .type)
        role = try container.decode(MessageRole.self, forKey: .role)
        index = try container.decode(Int.self, forKey: .index)
        timestamp = try container.decode(String.self, forKey: .timestamp)
        contentPreview = try container.decodeIfPresent(String.self, forKey: .contentPreview) ?? ""
        toolUses = try container.decodeIfPresent([ToolUse].self, forKey: .toolUses)
        parentToolUseId = try container.decodeIfPresent(String.self, forKey: .parentToolUseId)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        metadata = try container.decodeIfPresent(MessageMetadata.self, forKey: .metadata)

        // Decode content based on message type
        switch type {
        case .permissionRequest:
            let perm = try container.decode(PermissionRequestContent.self, forKey: .content)
            content = .permissionRequest(perm)
        case .inputRequest:
            let input = try container.decode(InputRequestContent.self, forKey: .content)
            content = .inputRequest(input)
        default:
            // Try blocks first, then fall back to string
            if let blocks = try? container.decode([ContentBlock].self, forKey: .content) {
                content = .blocks(blocks)
            } else if let text = try? container.decode(String.self, forKey: .content) {
                content = .text(text)
            } else {
                content = .text("")
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(messageId, forKey: .messageId)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(taskId, forKey: .taskId)
        try container.encode(type, forKey: .type)
        try container.encode(role, forKey: .role)
        try container.encode(index, forKey: .index)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(contentPreview, forKey: .contentPreview)
        try container.encodeIfPresent(toolUses, forKey: .toolUses)
        try container.encodeIfPresent(parentToolUseId, forKey: .parentToolUseId)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(metadata, forKey: .metadata)

        switch content {
        case .text(let s):
            try container.encode(s, forKey: .content)
        case .blocks(let b):
            try container.encode(b, forKey: .content)
        case .permissionRequest(let p):
            try container.encode(p, forKey: .content)
        case .inputRequest(let i):
            try container.encode(i, forKey: .content)
        }
    }
}
