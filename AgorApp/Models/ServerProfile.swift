import Foundation

struct ServerProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var url: String
    var isDefault: Bool

    init(id: UUID = UUID(), name: String, url: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.url = url
        self.isDefault = isDefault
    }
}
