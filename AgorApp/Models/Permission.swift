import Foundation

// MARK: - Permission Status

enum PermissionStatus: String, Codable {
    case pending
    case approved
    case denied
    case timedOut = "timed_out"
}

// MARK: - Permission Scope

enum PermissionScope: String, Codable {
    case once
    case project
    case user
    case local
}

// MARK: - Permission Request Content

struct PermissionRequestContent: Codable {
    let requestId: String
    var taskId: String?
    let toolName: String
    let toolInput: [String: AnyCodable]
    var toolUseId: String?
    var status: PermissionStatus
    var scope: PermissionScope?
    var approvedBy: String?
    var approvedAt: String?

    var isPending: Bool { status == .pending }
    var isResolved: Bool { status != .pending }

    var toolDisplayName: String {
        switch toolName.lowercased() {
        case "bash", "bash_cmd": "Bash"
        case "edit": "Edit"
        case "write": "Write"
        case "read": "Read"
        case "glob": "Glob"
        case "grep": "Grep"
        case "notebook_edit", "notebookedit": "Notebook Edit"
        default: toolName
        }
    }

    var toolIcon: String {
        switch toolName.lowercased() {
        case "bash", "bash_cmd": "terminal"
        case "edit": "pencil"
        case "write": "doc.text"
        case "read": "eye"
        case "glob", "grep": "magnifyingglass"
        default: "wrench"
        }
    }

    var inputPreview: String {
        if let command = toolInput["command"]?.stringValue {
            return command.count > 150 ? String(command.prefix(150)) + "..." : command
        }
        if let filePath = toolInput["file_path"]?.stringValue ?? toolInput["path"]?.stringValue {
            return filePath
        }
        return toolInput.keys.sorted().joined(separator: ", ")
    }

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case taskId = "task_id"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case status, scope
        case approvedBy = "approved_by"
        case approvedAt = "approved_at"
    }
}

// MARK: - Permission Decision (for POST)

struct PermissionDecision: Codable {
    let requestId: String
    var taskId: String?
    let allow: Bool
    var reason: String?
    var remember: Bool
    let scope: PermissionScope
    let decidedBy: String

    enum CodingKeys: String, CodingKey {
        case requestId = "requestId"
        case taskId = "taskId"
        case allow, reason, remember, scope
        case decidedBy = "decidedBy"
    }
}
