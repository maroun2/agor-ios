import Foundation

@Observable
final class MCPViewModel {
    var sessionMCPServers: [SessionMCPServer] = []
    var availableMCPServers: [MCPServer] = []
    var isLoading = false
    var error: String?

    private let client: AgorClient
    private let sessionId: String

    init(client: AgorClient, sessionId: String) {
        self.client = client
        self.sessionId = sessionId
    }

    func loadAll() async {
        isLoading = true
        error = nil
        async let sessionServers = loadSessionServers()
        async let available = loadAvailableServers()
        await sessionServers
        await available
        isLoading = false
    }

    private func loadSessionServers() async {
        do {
            let response: PaginatedResponse<SessionMCPServer> = try await client.getPaginated(
                "/sessions/\(sessionId)/mcp-servers"
            )
            sessionMCPServers = response.data
        } catch {
            self.error = "Failed to load session MCP servers"
        }
    }

    private func loadAvailableServers() async {
        do {
            let response: PaginatedResponse<MCPServer> = try await client.getPaginated(
                "/mcp-servers",
                query: ["scope": "global", "enabled": "true", "$limit": "50"]
            )
            availableMCPServers = response.data
        } catch {
            // Non-fatal — just can't add new ones
        }
    }

    /// Servers not yet added to this session
    var addableServers: [MCPServer] {
        let existingIds = Set(sessionMCPServers.map(\.mcpServerId))
        return availableMCPServers.filter { !existingIds.contains($0.mcpServerId) }
    }

    func addServer(_ server: MCPServer) async {
        struct AddBody: Codable {
            let mcpServerId: String
            enum CodingKeys: String, CodingKey { case mcpServerId = "mcpServerId" }
        }
        do {
            let _: SessionMCPServer = try await client.post(
                "/sessions/\(sessionId)/mcp-servers",
                body: AddBody(mcpServerId: server.mcpServerId)
            )
            await loadAll()
        } catch {
            self.error = "Failed to add server: \(error.localizedDescription)"
        }
    }

    func removeServer(_ mcpServerId: String) async {
        do {
            _ = try await client.delete("/sessions/\(sessionId)/mcp-servers/\(mcpServerId)")
            sessionMCPServers.removeAll { $0.mcpServerId == mcpServerId }
        } catch {
            self.error = "Failed to remove server: \(error.localizedDescription)"
        }
    }

    func toggleServer(_ mcpServerId: String, enabled: Bool) async {
        struct ToggleBody: Codable { let enabled: Bool }
        do {
            let _: SessionMCPServer = try await client.patch(
                "/sessions/\(sessionId)/mcp-servers/\(mcpServerId)",
                body: ToggleBody(enabled: enabled)
            )
            if let idx = sessionMCPServers.firstIndex(where: { $0.mcpServerId == mcpServerId }) {
                sessionMCPServers[idx].enabled = enabled
            }
        } catch {
            self.error = "Failed to update server"
        }
    }
}
