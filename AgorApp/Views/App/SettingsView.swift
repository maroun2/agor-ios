import SwiftUI

struct SettingsView: View {
    let appViewModel: AppViewModel
    let socketService: SocketService
    let onLogout: () -> Void
    var onServerSwitch: ((ServerProfile) -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Account Section
                Section("Account") {
                    if let user = appViewModel.currentUser {
                        HStack {
                            Text(user.emoji ?? "👤")
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                if let name = user.name {
                                    Text(name)
                                        .font(.subheadline.weight(.medium))
                                }
                                Text(user.email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button(role: .destructive) {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            onLogout()
                        }
                    } label: {
                        Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }

                // Connection Section
                Section("Connection") {
                    NavigationLink {
                        ServerListView(
                            profileManager: ServerProfileManager.shared,
                            onSwitch: { profile in
                                onServerSwitch?(profile)
                            }
                        )
                    } label: {
                        LabeledContent("Server") {
                            Text(ServerProfileManager.shared.activeProfile?.name ?? appViewModel.daemonURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    LabeledContent("Status") {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(socketService.connectionState == .connected ? .green : .red)
                                .frame(width: 6, height: 6)
                            Text(connectionLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    NavigationLink {
                        DebugLogView(client: appViewModel.client)
                    } label: {
                        Label("Debug Log", systemImage: "doc.text.magnifyingglass")
                    }
                }

                // About Section
                Section("About") {
                    LabeledContent("Version") {
                        Text("1.0.0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Build") {
                        Text(GitVersion.hash)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var connectionLabel: String {
        switch socketService.connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting..."
        case .reconnecting: "Reconnecting..."
        case .disconnected: "Disconnected"
        }
    }
}
