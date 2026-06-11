import Foundation

struct Worktree: Codable, Identifiable {
    let worktreeId: String
    let repoId: String
    let name: String
    let ref: String
    var refType: String?
    var path: String?
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

    // v21 uses branch_id, v19 uses worktree_id
    enum CodingKeys: String, CodingKey {
        case branchId = "branch_id"
        case worktreeId = "worktree_id"
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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        worktreeId = try (c.decodeIfPresent(String.self, forKey: .branchId)
                      ?? c.decodeIfPresent(String.self, forKey: .worktreeId)) ?? ""
        repoId = try c.decode(String.self, forKey: .repoId)
        name = try c.decode(String.self, forKey: .name)
        ref = try c.decode(String.self, forKey: .ref)
        refType = try c.decodeIfPresent(String.self, forKey: .refType)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        baseRef = try c.decodeIfPresent(String.self, forKey: .baseRef)
        baseSha = try c.decodeIfPresent(String.self, forKey: .baseSha)
        lastCommitSha = try c.decodeIfPresent(String.self, forKey: .lastCommitSha)
        trackingBranch = try c.decodeIfPresent(String.self, forKey: .trackingBranch)
        newBranch = try c.decodeIfPresent(Bool.self, forKey: .newBranch)
        boardId = try c.decodeIfPresent(String.self, forKey: .boardId)
        issueUrl = try c.decodeIfPresent(String.self, forKey: .issueUrl)
        pullRequestUrl = try c.decodeIfPresent(String.self, forKey: .pullRequestUrl)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived)
        archivedAt = try c.decodeIfPresent(String.self, forKey: .archivedAt)
        needsAttention = try c.decodeIfPresent(Bool.self, forKey: .needsAttention)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        createdBy = try c.decodeIfPresent(String.self, forKey: .createdBy)
        lastUsed = try c.decodeIfPresent(String.self, forKey: .lastUsed)
        scheduleEnabled = try c.decodeIfPresent(Bool.self, forKey: .scheduleEnabled)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(worktreeId, forKey: .branchId)
        try c.encode(repoId, forKey: .repoId)
        try c.encode(name, forKey: .name)
        try c.encode(ref, forKey: .ref)
        try c.encodeIfPresent(refType, forKey: .refType)
        try c.encodeIfPresent(path, forKey: .path)
        try c.encodeIfPresent(baseRef, forKey: .baseRef)
        try c.encodeIfPresent(baseSha, forKey: .baseSha)
        try c.encodeIfPresent(lastCommitSha, forKey: .lastCommitSha)
        try c.encodeIfPresent(trackingBranch, forKey: .trackingBranch)
        try c.encodeIfPresent(newBranch, forKey: .newBranch)
        try c.encodeIfPresent(boardId, forKey: .boardId)
        try c.encodeIfPresent(issueUrl, forKey: .issueUrl)
        try c.encodeIfPresent(pullRequestUrl, forKey: .pullRequestUrl)
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(archived, forKey: .archived)
        try c.encodeIfPresent(archivedAt, forKey: .archivedAt)
        try c.encodeIfPresent(needsAttention, forKey: .needsAttention)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encodeIfPresent(lastUsed, forKey: .lastUsed)
        try c.encodeIfPresent(scheduleEnabled, forKey: .scheduleEnabled)
    }
}
