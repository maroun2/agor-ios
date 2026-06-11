import Foundation

// MARK: - Session Status

enum SessionStatus: String, CaseIterable, Codable {
    case idle
    case running
    case stopping
    case awaitingPermission = "awaiting_permission"
    case awaitingInput = "awaiting_input"
    case timedOut = "timed_out"
    case completed
    case failed
    case unknown

    static var allCases: [SessionStatus] {
        [.idle, .running, .stopping, .awaitingPermission, .awaitingInput, .timedOut, .completed, .failed]
    }

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
        case .unknown: "Unknown"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionStatus(rawValue: raw) ?? .unknown
    }
}

// MARK: - Agentic Tool

enum AgenticToolName: String, CaseIterable, Codable {
    case claudeCode = "claude-code"
    case claudeCodeCli = "claude-code-cli"
    case codex
    case gemini
    case opencode
    case copilot
    case unknown

    static var allCases: [AgenticToolName] {
        [.claudeCode, .claudeCodeCli, .codex, .gemini, .opencode, .copilot]
    }

    var displayLabel: String {
        switch self {
        case .claudeCode, .claudeCodeCli: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .opencode: "OpenCode"
        case .copilot: "Copilot"
        case .unknown: "Agent"
        }
    }

    var iconName: String {
        switch self {
        case .claudeCode, .claudeCodeCli: "sparkle"
        case .codex: "terminal"
        case .gemini: "diamond"
        case .opencode: "chevron.left.forwardslash.chevron.right"
        case .copilot: "person.2"
        case .unknown: "questionmark.circle"
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgenticToolName(rawValue: raw) ?? .unknown
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
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PermissionMode(rawValue: raw) ?? .unknown
    }
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
    var children: [String]?

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

    // v21 uses branch_id/branch_board_id/scheduled_from_branch
    // v19 uses worktree_id/worktree_board_id/scheduled_from_worktree
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
        case branchId = "branch_id"
        case worktreeId = "worktree_id"
        case branchBoardId = "branch_board_id"
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
        case scheduledFromBranch = "scheduled_from_branch"
        case scheduledFromWorktree = "scheduled_from_worktree"
        case readyForPrompt = "ready_for_prompt"
        case archived
        case archivedReason = "archived_reason"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        agenticTool = try c.decode(AgenticToolName.self, forKey: .agenticTool)
        agenticToolVersion = try c.decodeIfPresent(String.self, forKey: .agenticToolVersion)
        sdkSessionId = try c.decodeIfPresent(String.self, forKey: .sdkSessionId)
        status = try c.decode(SessionStatus.self, forKey: .status)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        lastUpdated = try c.decode(String.self, forKey: .lastUpdated)
        createdBy = try c.decode(String.self, forKey: .createdBy)
        unixUsername = try c.decodeIfPresent(String.self, forKey: .unixUsername)
        // v21: branch_id, v19: worktree_id
        worktreeId = try (c.decodeIfPresent(String.self, forKey: .branchId)
                      ?? c.decodeIfPresent(String.self, forKey: .worktreeId)) ?? ""
        worktreeBoardId = try c.decodeIfPresent(String.self, forKey: .branchBoardId)
                       ?? c.decodeIfPresent(String.self, forKey: .worktreeBoardId)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        gitState = try c.decodeIfPresent(GitState.self, forKey: .gitState)
        genealogy = try c.decodeIfPresent(SessionGenealogy.self, forKey: .genealogy)
        tasks = try c.decodeIfPresent([String].self, forKey: .tasks)
        messageCount = try c.decodeIfPresent(Int.self, forKey: .messageCount)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        permissionConfig = try c.decodeIfPresent(PermissionConfig.self, forKey: .permissionConfig)
        modelConfig = try c.decodeIfPresent(ModelConfig.self, forKey: .modelConfig)
        currentContextUsage = try c.decodeIfPresent(Int.self, forKey: .currentContextUsage)
        contextWindowLimit = try c.decodeIfPresent(Int.self, forKey: .contextWindowLimit)
        scheduledFromWorktree = try c.decodeIfPresent(Bool.self, forKey: .scheduledFromBranch)
                             ?? c.decodeIfPresent(Bool.self, forKey: .scheduledFromWorktree)
        readyForPrompt = try c.decodeIfPresent(Bool.self, forKey: .readyForPrompt)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived)
        archivedReason = try c.decodeIfPresent(String.self, forKey: .archivedReason)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(agenticTool, forKey: .agenticTool)
        try c.encodeIfPresent(agenticToolVersion, forKey: .agenticToolVersion)
        try c.encodeIfPresent(sdkSessionId, forKey: .sdkSessionId)
        try c.encode(status, forKey: .status)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(lastUpdated, forKey: .lastUpdated)
        try c.encode(createdBy, forKey: .createdBy)
        try c.encodeIfPresent(unixUsername, forKey: .unixUsername)
        try c.encode(worktreeId, forKey: .branchId)
        try c.encodeIfPresent(worktreeBoardId, forKey: .branchBoardId)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(gitState, forKey: .gitState)
        try c.encodeIfPresent(genealogy, forKey: .genealogy)
        try c.encodeIfPresent(tasks, forKey: .tasks)
        try c.encodeIfPresent(messageCount, forKey: .messageCount)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encodeIfPresent(permissionConfig, forKey: .permissionConfig)
        try c.encodeIfPresent(modelConfig, forKey: .modelConfig)
        try c.encodeIfPresent(currentContextUsage, forKey: .currentContextUsage)
        try c.encodeIfPresent(contextWindowLimit, forKey: .contextWindowLimit)
        try c.encodeIfPresent(scheduledFromWorktree, forKey: .scheduledFromBranch)
        try c.encodeIfPresent(readyForPrompt, forKey: .readyForPrompt)
        try c.encodeIfPresent(archived, forKey: .archived)
        try c.encodeIfPresent(archivedReason, forKey: .archivedReason)
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
