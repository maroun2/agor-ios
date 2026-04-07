import Foundation

struct MCPServer: Codable, Identifiable {
    let mcpServerId: String
    let name: String
    var displayName: String?
    var description: String?
    var transport: String?
    var enabled: Bool
    var scope: String?

    var id: String { mcpServerId }

    var label: String {
        displayName ?? name
    }

    enum CodingKeys: String, CodingKey {
        case mcpServerId = "mcp_server_id"
        case name
        case displayName = "display_name"
        case description
        case transport
        case enabled
        case scope
    }
}

struct SessionMCPServer: Codable, Identifiable {
    let sessionId: String
    let mcpServerId: String
    var enabled: Bool
    var addedAt: String?
    var mcpServer: MCPServer?

    var id: String { mcpServerId }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case mcpServerId = "mcp_server_id"
        case enabled
        case addedAt = "added_at"
        case mcpServer = "mcp_server"
    }
}
