import Foundation

struct Repo: Codable, Identifiable {
    let repoId: String
    let name: String

    var id: String { repoId }

    enum CodingKeys: String, CodingKey {
        case repoId = "repo_id"
        case name
    }
}
