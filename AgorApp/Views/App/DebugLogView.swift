import SwiftUI

struct DebugLogView: View {
    let client: AgorClient

    @State private var logger = AppLogger.shared
    @State private var showSessionPicker = false
    @State private var sessions: [Session] = []
    @State private var isLoadingSessions = false
    @State private var isSending = false
    @State private var sendError: String?

    var body: some View {
        List {
            if logger.entries.isEmpty {
                ContentUnavailableView(
                    "No Log Entries",
                    systemImage: "doc.text",
                    description: Text("Logs from network requests, auth, and socket events will appear here.")
                )
            } else {
                ForEach(logger.entries.reversed()) { entry in
                    LogEntryRow(entry: entry)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Debug Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showSessionPicker = true
                    } label: {
                        Label("Send to Session", systemImage: "paperplane")
                    }
                    .disabled(logger.entries.isEmpty)

                    ShareLink(
                        item: logger.export(),
                        subject: Text("Agor Debug Log"),
                        message: Text("Debug log exported from Agor iOS app")
                    ) {
                        Label("Share Log", systemImage: "square.and.arrow.up")
                    }
                    .disabled(logger.entries.isEmpty)

                    Divider()

                    Button(role: .destructive) {
                        logger.clear()
                    } label: {
                        Label("Clear Log", systemImage: "trash")
                    }
                    .disabled(logger.entries.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showSessionPicker) {
            SessionPickerSheet(
                sessions: sessions,
                isLoading: isLoadingSessions,
                isSending: isSending,
                sendError: sendError,
                onSelect: { session in
                    sendLogToSession(session)
                },
                onDismiss: {
                    showSessionPicker = false
                    sendError = nil
                }
            )
            .task {
                await loadSessions()
            }
        }
    }

    private func loadSessions() async {
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        do {
            let response: PaginatedResponse<Session> = try await client.getPaginated(
                "/sessions",
                query: [
                    "archived": "false",
                    "$limit": "20",
                    "$sort[last_updated]": "-1",
                ]
            )
            sessions = response.data
        } catch {
            AppLogger.shared.log("Failed to load sessions for picker: \(error.localizedDescription)", level: .error, category: "DebugLog")
        }
    }

    private func sendLogToSession(_ session: Session) {
        let logText = """
        # Debug Log from iOS App
        Exported: \(ISO8601DateFormatter().string(from: Date()))
        Entries: \(logger.entries.count)

        ```
        \(logger.export())
        ```
        """

        isSending = true
        sendError = nil

        Task {
            do {
                struct PromptBody: Encodable {
                    let prompt: String
                }
                _ = try await client.postRaw(
                    "/sessions/\(session.sessionId)/prompt",
                    body: PromptBody(prompt: logText)
                )
                showSessionPicker = false
                AppLogger.shared.log("Sent debug log to session '\(session.displayTitle)'", category: "DebugLog")
            } catch {
                sendError = error.localizedDescription
                AppLogger.shared.log("Failed to send log to session: \(error.localizedDescription)", level: .error, category: "DebugLog")
            }
            isSending = false
        }
    }
}

// MARK: - Log Entry Row

private struct LogEntryRow: View {
    let entry: AppLogger.LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: entry.level.symbol)
                    .font(.caption2)
                    .foregroundStyle(levelColor)

                Text(entry.level.rawValue.uppercased())
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(levelColor)

                Text(entry.category)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Text(entry.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(5)
        }
        .padding(.vertical, 2)
    }

    private var levelColor: Color {
        switch entry.level {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        case .debug: .gray
        }
    }
}

// MARK: - Session Picker Sheet

private struct SessionPickerSheet: View {
    let sessions: [Session]
    let isLoading: Bool
    let isSending: Bool
    let sendError: String?
    let onSelect: (Session) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading sessions...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sessions.isEmpty {
                    ContentUnavailableView(
                        "No Sessions",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("No active sessions found.")
                    )
                } else {
                    List {
                        if let error = sendError {
                            Section {
                                Label(error, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }

                        ForEach(sessions, id: \.sessionId) { session in
                            Button {
                                onSelect(session)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.displayTitle)
                                            .font(.subheadline.weight(.medium))
                                        Text(session.status.rawValue)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if isSending {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                }
                            }
                            .disabled(isSending)
                        }
                    }
                }
            }
            .navigationTitle("Send Log to Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onDismiss() }
                        .disabled(isSending)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
