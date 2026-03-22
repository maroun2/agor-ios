import Foundation

enum UserRole: String, Codable {
    case owner
    case admin
    case member
    case viewer
}

struct User: Codable, Identifiable {
    let userId: String
    let email: String
    var name: String?
    var emoji: String?
    var avatar: String?
    var role: UserRole?
    var onboardingCompleted: Bool?
    var mustChangePassword: Bool?
    var createdAt: String?
    var updatedAt: String?
    var unixUsername: String?

    var id: String { userId }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return email.components(separatedBy: "@").first ?? email
    }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case email, name, emoji, avatar, role
        case onboardingCompleted = "onboarding_completed"
        case mustChangePassword = "must_change_password"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case unixUsername = "unix_username"
    }
}
