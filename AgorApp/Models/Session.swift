import Foundation

// MARK: - Session Status

enum SessionStatus: String, Codable, CaseIterable {
    case idle
    case running
    case stopping
    case awaitingPermission = "awaiting_permission"
    case awaitingInput = "awaiting_input"
    case timedOut = "timed_out"
    case completed
    case failed

    var needsAttention: Bool {
        self == .awaitingPermission || self == .awaitingInput
    }

    var isActive: Bool {
        self == .running || self == .stopping || needsAttention
    }

    var displayLabel: String {
        switch self {
        case .idle: "Idle"
        case .running: "Running"
        case .stopping: "Stopping"
        case .awaitingPermission: "Awaiting Permission"
        case .awaitingInput: "Awaiting Input"
        case .timedOut: "Timed Out"
        case .completed: "Completed"
        case .failed: "Failed"
        }
    }
}

// MARK: - Agentic Tool

enum AgenticToolName: String, Codable, CaseIterable {
    case claudeCode = "claude-code"
    case codex
    case gemini
    case opencode
    case copilot

    var displayLabel: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .opencode: "OpenCode"
        case .copilot: "Copilot"
        }
    }

    var iconName: String {
        switch self {
        case .claudeCode: "sparkle"
        case .codex: "terminal"
        case .gemini: "diamond"
        case .opencode: "chevron.left.forwardslash.chevron.right"
        case .copilot: "person.2"
        }
    }
}

// MARK: - Permission Mode

enum PermissionMode: String, Codable {
    case `default`
    case acceptEdits
    case bypassPermissions
    case plan
    case dontAsk
    case autoEdit
    case yolo
    case ask
    case auto
    case onFailure = "on-failure"
    case allowAll = "allow-all"
}

// MARK: - Git State

struct GitState: Codable {
    let ref: String
    let baseSha: String
    let currentSha: String

    enum CodingKeys: String, CodingKey {
        case ref
        case baseSha = "base_sha"
        case currentSha = "current_sha"
    }
}

// MARK: - Session Genealogy

struct SessionGenealogy: Codable {
    var forkedFromSessionId: String?
    var forkPointTaskId: String?
    var forkPointMessageIndex: Int?
    var parentSessionId: String?
    var spawnPointTaskId: String?
    var spawnPointMessageIndex: Int?
    var children: [String]

    enum CodingKeys: String, CodingKey {
        case forkedFromSessionId = "forked_from_session_id"
        case forkPointTaskId = "fork_point_task_id"
        case forkPointMessageIndex = "fork_point_message_index"
        case parentSessionId = "parent_session_id"
        case spawnPointTaskId = "spawn_point_task_id"
        case spawnPointMessageIndex = "spawn_point_message_index"
        case children
    }
}

// MARK: - Permission Config

struct PermissionConfig: Codable {
    var mode: PermissionMode?

    enum CodingKeys: String, CodingKey {
        case mode
    }
}

// MARK: - Model Config

struct ModelConfig: Codable {
    var mode: String?
    var model: String?
    var updatedAt: String?
    var notes: String?
    var thinkingMode: String?
    var manualThinkingTokens: Int?
    var provider: String?

    enum CodingKeys: String, CodingKey {
        case mode, model, notes, provider
        case updatedAt = "updated_at"
        case thinkingMode
        case manualThinkingTokens
    }
}

// MARK: - Session

struct Session: Codable, Identifiable {
    let sessionId: String
    let agenticTool: AgenticToolName
    var agenticToolVersion: String?
    var sdkSessionId: String?
    var status: SessionStatus
    let createdAt: String
    var lastUpdated: String
    let createdBy: String
    var unixUsername: String?
    let worktreeId: String
    var worktreeBoardId: String?
    var url: String?
    var gitState: GitState?
    var genealogy: SessionGenealogy?
    var tasks: [String]?
    var messageCount: Int?
    var title: String?
    var description: String?
    var permissionConfig: PermissionConfig?
    var modelConfig: ModelConfig?
    var currentContextUsage: Int?
    var contextWindowLimit: Int?
    var scheduledFromWorktree: Bool?
    var readyForPrompt: Bool?
    var archived: Bool?
    var archivedReason: String?

    var id: String { sessionId }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let description, !description.isEmpty { return description }
        return "Session \(String(sessionId.prefix(8)))"
    }

    var hasExplicitTitle: Bool {
        guard let title, !title.isEmpty else { return false }
        if title.hasPrefix("[Scheduled run") { return false }
        return true
    }

    var isPlanMode: Bool {
        permissionConfig?.mode == .plan
    }

    var isPromptable: Bool {
        status == .idle || readyForPrompt == true
    }

    var canAcceptInput: Bool {
        status == .idle || status == .running || readyForPrompt == true
    }

    var isScheduled: Bool {
        scheduledFromWorktree == true || (title?.hasPrefix("[Scheduled ") == true)
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case agenticTool = "agentic_tool"
        case agenticToolVersion = "agentic_tool_version"
        case sdkSessionId = "sdk_session_id"
        case status
        case createdAt = "created_at"
        case lastUpdated = "last_updated"
        case createdBy = "created_by"
        case unixUsername = "unix_username"
        case worktreeId = "worktree_id"
        case worktreeBoardId = "worktree_board_id"
        case url
        case gitState = "git_state"
        case genealogy
        case tasks
        case messageCount = "message_count"
        case title, description
        case permissionConfig = "permission_config"
        case modelConfig = "model_config"
        case currentContextUsage = "current_context_usage"
        case contextWindowLimit = "context_window_limit"
        case scheduledFromWorktree = "scheduled_from_worktree"
        case readyForPrompt = "ready_for_prompt"
        case archived
        case archivedReason = "archived_reason"
    }
}

// MARK: - Equatable

extension Session: Equatable {
    static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.sessionId == rhs.sessionId &&
        lhs.status == rhs.status &&
        lhs.title == rhs.title &&
        lhs.description == rhs.description &&
        lhs.lastUpdated == rhs.lastUpdated &&
        lhs.readyForPrompt == rhs.readyForPrompt &&
        lhs.currentContextUsage == rhs.currentContextUsage &&
        lhs.archived == rhs.archived &&
        lhs.messageCount == rhs.messageCount
    }
}
