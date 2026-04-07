import SwiftUI

struct MCPServerListView: View {
    let viewModel: MCPViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.sessionMCPServers.isEmpty {
                    ProgressView("Loading MCP servers...")
                } else {
                    serverList
                }
            }
            .navigationTitle("MCP Servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await viewModel.loadAll()
            }
        }
    }

    private var serverList: some View {
        List {
            if !viewModel.sessionMCPServers.isEmpty {
                Section("Active Servers") {
                    ForEach(viewModel.sessionMCPServers) { server in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.mcpServer?.label ?? server.mcpServerId)
                                    .font(.subheadline)
                                if let desc = server.mcpServer?.description {
                                    Text(desc)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                if let transport = server.mcpServer?.transport {
                                    Text(transport)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { server.enabled },
                                set: { newValue in
                                    Task { await viewModel.toggleServer(server.mcpServerId, enabled: newValue) }
                                }
                            ))
                            .labelsHidden()
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await viewModel.removeServer(server.mcpServerId) }
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if !viewModel.addableServers.isEmpty {
                Section("Available Servers") {
                    ForEach(viewModel.addableServers) { server in
                        Button {
                            Task { await viewModel.addServer(server) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.label)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    if let desc = server.description {
                                        Text(desc)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    if let transport = server.transport {
                                        Text(transport)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }
            }

            if viewModel.sessionMCPServers.isEmpty && viewModel.addableServers.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(
                    "No MCP Servers",
                    systemImage: "server.rack",
                    description: Text("No MCP servers configured. Add servers in the Agor web UI.")
                )
            }

            if let error = viewModel.error {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}
