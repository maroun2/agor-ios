import Foundation

struct Board: Codable, Identifiable {
    let boardId: String
    let name: String
    var slug: String?
    var description: String?
    let createdAt: String
    var lastUpdated: String
    let createdBy: String
    var color: String?
    var icon: String?
    var backgroundColor: String?

    var id: String { boardId }

    var displayIcon: String {
        icon ?? "📋"
    }

    enum CodingKeys: String, CodingKey {
        case boardId = "board_id"
        case name, slug, description
        case createdAt = "created_at"
        case lastUpdated = "last_updated"
        case createdBy = "created_by"
        case color, icon
        case backgroundColor = "background_color"
    }
}
