import SwiftUI

struct SidebarView: View {
    let viewModel: NavigationViewModel
    @Binding var selectedSessionId: String?

    var body: some View {
        List(selection: $selectedSessionId) {
            // Needs Attention Section
            if !viewModel.attentionSessions.isEmpty {
                Section {
                    ForEach(viewModel.attentionSessions) { session in
                        NavigationLink(value: session.sessionId) {
                            SessionRow(session: session, showAttentionBadge: true)
                        }
                    }
                } header: {
                    Label("Needs Attention", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            // Boards
            ForEach(viewModel.boardNodes) { boardNode in
                Section {
                    DisclosureGroup(isExpanded: Binding(
                        get: { boardNode.isExpanded },
                        set: { boardNode.isExpanded = $0 }
                    )) {
                        if boardNode.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            ForEach(boardNode.worktrees) { wtNode in
                                WorktreeSection(
                                    worktreeNode: wtNode,
                                    selectedSessionId: $selectedSessionId
                                )
                            }
                        }
                    } label: {
                        BoardRow(board: boardNode.board, attentionCount: boardNode.attentionCount)
                    }
                }
            }

            // Version footer
            Section {
                Text(GitVersion.hash)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Agor")
        .refreshable {
            await viewModel.refresh()
        }
        .overlay {
            if viewModel.isLoading && viewModel.boardNodes.isEmpty {
                ProgressView("Loading...")
            } else if let error = viewModel.error, viewModel.boardNodes.isEmpty {
                ContentUnavailableView {
                    Label("Connection Error", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        Task { await viewModel.refresh() }
                    }
                }
            } else if viewModel.boardNodes.isEmpty && !viewModel.isLoading {
                ContentUnavailableView(
                    "No Boards",
                    systemImage: "rectangle.on.rectangle.slash",
                    description: Text("Create a board in Agor to get started")
                )
            }
        }
    }
}

// MARK: - Worktree Section (expandable)

private struct WorktreeSection: View {
    let worktreeNode: WorktreeNode
    @Binding var selectedSessionId: String?

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { worktreeNode.isExpanded },
            set: { worktreeNode.isExpanded = $0 }
        )) {
            if worktreeNode.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if worktreeNode.sessions.isEmpty {
                Text("No sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(worktreeNode.sessions) { session in
                    NavigationLink(value: session.sessionId) {
                        SessionRow(session: session)
                    }
                }
            }
        } label: {
            WorktreeRow(worktree: worktreeNode.worktree, attentionCount: worktreeNode.attentionCount)
        }
    }
}
