import Foundation

struct Worktree: Codable, Identifiable {
    let worktreeId: String
    let repoId: String
    let name: String
    let ref: String
    var refType: String?
    let path: String
    var baseRef: String?
    var baseSha: String?
    var lastCommitSha: String?
    var trackingBranch: String?
    var newBranch: Bool?
    var boardId: String?
    var issueUrl: String?
    var pullRequestUrl: String?
    var notes: String?
    var archived: Bool?
    var archivedAt: String?
    var needsAttention: Bool?
    let createdAt: String
    var updatedAt: String?
    var createdBy: String?
    var lastUsed: String?
    var scheduleEnabled: Bool?

    var id: String { worktreeId }

    var displayName: String {
        name.isEmpty ? ref : name
    }

    enum CodingKeys: String, CodingKey {
        case worktreeId = "branch_id"
        case repoId = "repo_id"
        case name, ref
        case refType = "ref_type"
        case path
        case baseRef = "base_ref"
        case baseSha = "base_sha"
        case lastCommitSha = "last_commit_sha"
        case trackingBranch = "tracking_branch"
        case newBranch = "new_branch"
        case boardId = "board_id"
        case issueUrl = "issue_url"
        case pullRequestUrl = "pull_request_url"
        case notes, archived
        case archivedAt = "archived_at"
        case needsAttention = "needs_attention"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case createdBy = "created_by"
        case lastUsed = "last_used"
        case scheduleEnabled = "schedule_enabled"
    }
}
