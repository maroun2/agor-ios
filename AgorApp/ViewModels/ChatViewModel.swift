import Foundation
import SwiftUI

// MARK: - Display Item (union of message types for the list)

enum DisplayItem: Identifiable {
    case taskHeader(AgorTask)
    case message(Message)
    case streaming(StreamingMessage)

    var id: String {
        switch self {
        case .taskHeader(let task): "task-\(task.taskId)"
        case .message(let msg): "msg-\(msg.messageId)"
        case .streaming(let s): "stream-\(s.messageId)"
        }
    }

    var sessionId: String {
        switch self {
        case .taskHeader(let t): t.sessionId
        case .message(let m): m.sessionId
        case .streaming(let s): s.sessionId
        }
    }
}

// MARK: - Chat ViewModel

@Observable
final class ChatViewModel {
    var currentSessionId: String?
    var currentSession: Session?
    var messages: [Message] = []
    var tasks: [AgorTask] = []
    var displayItems: [DisplayItem] = []
    var isLoadingMessages = false
    var isSendingPrompt = false
    var error: String?
    var isStoppingSession = false
    private static let draftKeyPrefix = "agor.draft."

    var promptText: String = "" {
        didSet {
            guard let sessionId = currentSessionId else { return }
            if promptText.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.draftKeyPrefix + sessionId)
            } else {
                UserDefaults.standard.set(promptText, forKey: Self.draftKeyPrefix + sessionId)
            }
        }
    }

    // Collapsed tasks
    var collapsedTaskIds: Set<String> = []

    // Incremented only when a new message arrives at the bottom (not when prepending old ones)
    var scrollToBottomToken: Int = 0

    private var rebuildTask: Task<Void, Never>?

    func toggleTaskCollapsed(_ taskId: String) {
        if collapsedTaskIds.contains(taskId) {
            collapsedTaskIds.remove(taskId)
            _rebuildDisplayItemsNow()
            // Load messages for this task if not yet in memory
            if let task = tasks.first(where: { $0.taskId == taskId }) {
                Task { await loadTaskMessagesIfNeeded(task) }
            }
        } else {
            collapsedTaskIds.insert(taskId)
            _rebuildDisplayItemsNow()
        }
    }

    // Streaming
    var activeStreams: [String: StreamingMessage] = [:]

    // Pagination
    var hasMore = true
    private var currentSkip = 0
    private let pageSize = 50
    private var messagePollingTimer: Timer?

    // Dependencies
    var userId: String
    let client: AgorClient
    private let socketService: SocketService
    private let streamingService: StreamingService

    init(client: AgorClient, socketService: SocketService, streamingService: StreamingService, userId: String) {
        self.client = client
        self.socketService = socketService
        self.streamingService = streamingService
        self.userId = userId
        setupSocketHandlers()
        setupStreamingHandlers()
    }

    // MARK: - Session Selection

    func selectSession(_ sessionId: String) {
        guard sessionId != currentSessionId else { return }
        AppLogger.shared.log("[Chat] selectSession \(sessionId)", level: .info, category: "Chat")
        stopMessagePolling()
        currentSessionId = sessionId
        messages = []
        tasks = []
        displayItems = []
        activeStreams = [:]
        collapsedTaskIds = []
        currentSkip = 0
        hasMore = true
        error = nil
        // Restore draft for this session (set directly to avoid didSet writing back before session is set)
        promptText = UserDefaults.standard.string(forKey: Self.draftKeyPrefix + sessionId) ?? ""

        Task {
            await loadSession(sessionId)
            // Mark as viewed if server flagged ready_for_prompt
            if currentSession?.readyForPrompt == true {
                await markSessionViewed(sessionId)
            }
            await loadTasks(sessionId)
            await loadMessages(sessionId)
            startMessagePolling()
        }
    }

    func refreshCurrentSession() {
        guard let sessionId = currentSessionId else { return }
        stopMessagePolling()
        // Clear stale streaming state (e.g., missed thinking:end while backgrounded)
        streamingService.clearStreams(for: sessionId)
        activeStreams = streamingService.activeStreams
        Task {
            await loadSession(sessionId)
            await loadTasks(sessionId)
            resetMessagePagination()
            await loadMessages(sessionId)
            startMessagePolling()
        }
    }

    // MARK: - Load Data

    private func loadSession(_ sessionId: String) async {
        do {
            let session: Session = try await client.get("/sessions/\(sessionId)")
            if currentSessionId == sessionId {
                currentSession = session
            }
        } catch {
            self.error = "Failed to load session"
        }
    }

    private func loadTasks(_ sessionId: String) async {
        do {
            let response: PaginatedResponse<AgorTask> = try await client.getPaginated(
                "/tasks",
                query: [
                    "session_id": sessionId,
                    "$sort[created_at]": "1",
                    "$limit": "100",
                ]
            )
            if currentSessionId == sessionId {
                tasks = response.data
                AppLogger.shared.log("[Chat] loadTasks: \(response.data.count) tasks loaded", level: .debug, category: "Chat")
                // Collapse all tasks except the last one
                let lastId = response.data.last?.taskId
                collapsedTaskIds = Set(response.data.compactMap { $0.taskId != lastId ? $0.taskId : nil })
                rebuildDisplayItems()
            }
        } catch {
            // Non-fatal
        }
    }

    func loadMessages(_ sessionId: String) async {
        isLoadingMessages = true
        do {
            if currentSkip == 0 {
                // Initial load: get the total first so we can jump to the last page
                let count: PaginatedResponse<Message> = try await client.getPaginated(
                    "/messages",
                    query: ["session_id": sessionId, "$limit": "1"]
                )
                let total = count.total
                let startSkip = max(0, total - pageSize)
                let response: PaginatedResponse<Message> = try await client.getPaginated(
                    "/messages",
                    query: [
                        "session_id": sessionId,
                        "$sort[index]": "1",
                        "$limit": "\(pageSize)",
                        "$skip": "\(startSkip)",
                    ]
                )
                if currentSessionId == sessionId {
                    messages = response.data
                    AppLogger.shared.log("[Chat] loadMessages: \(response.data.count) messages loaded", level: .debug, category: "Chat")
                    hasMore = startSkip > 0
                    // currentSkip tracks how many messages from the tail we've loaded
                    // For "load earlier", we go backwards from startSkip
                    currentSkip = startSkip
                    rebuildDisplayItems()
                    scrollToBottomToken += 1
                }
            } else {
                // Load earlier: fetch the page just before what we have
                let prevSkip = max(0, currentSkip - pageSize)
                let response: PaginatedResponse<Message> = try await client.getPaginated(
                    "/messages",
                    query: [
                        "session_id": sessionId,
                        "$sort[index]": "1",
                        "$limit": "\(pageSize)",
                        "$skip": "\(prevSkip)",
                    ]
                )
                if currentSessionId == sessionId {
                    messages = response.data + messages  // prepend older page
                    AppLogger.shared.log("[Chat] loadMessages: \(response.data.count) messages loaded", level: .debug, category: "Chat")
                    hasMore = prevSkip > 0
                    currentSkip = prevSkip
                    rebuildDisplayItems()
                }
            }
        } catch {
            AppLogger.shared.log("[Chat] loadMessages ERROR: \(error.localizedDescription)", level: .error, category: "Chat")
            self.error = "Failed to load messages"
        }
        isLoadingMessages = false
    }

    func loadMore() async {
        guard hasMore, !isLoadingMessages, let sessionId = currentSessionId else { return }
        await loadMessages(sessionId)
    }

    func resetMessagePagination() {
        // Don't clear messages here — they'll be replaced on successful reload.
        // selectSession already clears messages before switching sessions.
        currentSkip = 0
        hasMore = true
    }

    private func loadTaskMessagesIfNeeded(_ task: AgorTask) async {
        guard let sessionId = currentSessionId else { return }
        // Skip if we already have messages for this task
        guard !messages.contains(where: { $0.taskId == task.taskId }) else { return }

        do {
            let response: PaginatedResponse<Message> = try await client.getPaginated(
                "/messages",
                query: [
                    "task_id": task.taskId,
                    "$sort[index]": "1",
                    "$limit": "200",
                ]
            )
            guard currentSessionId == sessionId, !response.data.isEmpty else { return }
            let existingIds = Set(messages.map(\.messageId))
            let newMessages = response.data.filter { !existingIds.contains($0.messageId) }
            guard !newMessages.isEmpty else { return }
            messages = (messages + newMessages).sorted { $0.index < $1.index }
            rebuildDisplayItems()
        } catch {
            // Non-fatal — task header still shows, just without messages
        }
    }

    // MARK: - Send Prompt

    func sendPrompt() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let sessionId = currentSessionId else { return }
        AppLogger.shared.log("[Chat] sendPrompt to \(sessionId) (\(text.count) chars)", level: .debug, category: "Chat")
        promptText = ""
        isSendingPrompt = true

        Task {
            do {
                struct PromptBody: Codable {
                    let prompt: String
                }
                _ = try await client.postRaw(
                    "/sessions/\(sessionId)/prompt",
                    body: PromptBody(prompt: text)
                )
            } catch {
                AppLogger.shared.log("[Chat] sendPrompt ERROR: \(error.localizedDescription)", level: .error, category: "Chat")
                self.error = "Failed to send prompt: \(error.localizedDescription)"
            }
            isSendingPrompt = false
        }
    }

    // MARK: - File Upload

    var isUploading = false

    func uploadAndInsertReference(fileData: Data, fileName: String, mimeType: String) {
        guard let sessionId = currentSessionId else { return }
        isUploading = true
        Task {
            do {
                let response = try await client.uploadFile(
                    sessionId: sessionId,
                    fileData: fileData,
                    fileName: fileName,
                    mimeType: mimeType
                )
                if let file = response.files.first {
                    let reference = "@\(file.path)"
                    if promptText.isEmpty {
                        promptText = reference + " "
                    } else {
                        promptText += " " + reference + " "
                    }
                    AppLogger.shared.log("[Chat] uploaded \(fileName) → \(file.path)", level: .info, category: "Chat")
                }
            } catch {
                self.error = "Upload failed: \(error.localizedDescription)"
                AppLogger.shared.log("[Chat] upload ERROR: \(error.localizedDescription)", level: .error, category: "Chat")
            }
            isUploading = false
        }
    }

    func uploadDebugLog() {
        let logText = AppLogger.shared.export()
        guard let data = logText.data(using: .utf8) else { return }
        let fileName = "debug-log-\(Int(Date().timeIntervalSince1970)).txt"
        uploadAndInsertReference(fileData: data, fileName: fileName, mimeType: "text/plain")
    }

    // MARK: - Mark Viewed

    private func markSessionViewed(_ sessionId: String) async {
        struct ViewedBody: Codable {
            let readyForPrompt: Bool
            enum CodingKeys: String, CodingKey { case readyForPrompt = "ready_for_prompt" }
        }
        let updated: Session? = try? await client.patch(
            "/sessions/\(sessionId)",
            body: ViewedBody(readyForPrompt: false)
        )
        if let updated, currentSessionId == sessionId {
            currentSession = updated
        }
    }

    // MARK: - Archive Session

    func archiveCurrentSession() {
        guard let sessionId = currentSessionId else { return }
        AppLogger.shared.log("[Chat] archiveSession \(sessionId)", level: .info, category: "Chat")
        Task {
            do {
                struct ArchiveBody: Codable { let archived: Bool }
                let _: Session = try await client.patch("/sessions/\(sessionId)", body: ArchiveBody(archived: true))
                currentSessionId = nil
            } catch {
                self.error = "Failed to archive session"
            }
        }
    }

    // MARK: - Reset Session (Archive + Create New)

    func resetSession(onRefreshSidebar: @escaping () async -> Void) {
        guard let session = currentSession, let sessionId = currentSessionId else { return }
        let worktreeId = session.worktreeId
        let agenticTool = session.agenticTool
        let sessionTitle = session.title

        Task {
            do {
                // Archive the current session
                AppLogger.shared.log("[Chat] resetSession: archiving \(sessionId)", level: .info, category: "Chat")
                struct ArchiveBody: Codable { let archived: Bool }
                let _: Session = try await client.patch("/sessions/\(sessionId)", body: ArchiveBody(archived: true))

                // Create a new session on the same worktree
                struct CreateSessionBody: Codable {
                    let worktreeId: String
                    let agenticTool: AgenticToolName
                    let status: SessionStatus
                    var title: String?
                    enum CodingKeys: String, CodingKey {
                        case worktreeId = "worktree_id"
                        case agenticTool = "agentic_tool"
                        case status
                        case title
                    }
                }
                let newSession: Session = try await client.post(
                    "/sessions",
                    body: CreateSessionBody(worktreeId: worktreeId, agenticTool: agenticTool, status: .idle, title: sessionTitle)
                )
                AppLogger.shared.log("[Chat] resetSession: created new session \(newSession.sessionId)", level: .info, category: "Chat")

                // Switch to the new session
                selectSession(newSession.sessionId)

                // Refresh sidebar so it shows the new session
                await onRefreshSidebar()
            } catch {
                AppLogger.shared.log("[Chat] resetSession ERROR: \(error.localizedDescription)", level: .error, category: "Chat")
                self.error = "Failed to reset session"
            }
        }
    }

    // MARK: - Stop Session

    func stopSession() {
        guard let sessionId = currentSessionId, canStopSession else { return }
        isStoppingSession = true
        Task {
            do {
                struct EmptyBody: Codable {}
                _ = try await client.postRaw("/sessions/\(sessionId)/stop", body: EmptyBody())
            } catch {
                self.error = "Failed to stop session: \(error.localizedDescription)"
            }
            isStoppingSession = false
        }
    }

    // MARK: - Message Polling

    func startMessagePolling() {
        stopMessagePolling()
        messagePollingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, let sessionId = self.currentSessionId else { return }
            Task { await self.checkForNewMessages(sessionId) }
        }
    }

    func stopMessagePolling() {
        messagePollingTimer?.invalidate()
        messagePollingTimer = nil
    }

    private func checkForNewMessages(_ sessionId: String) async {
        guard sessionId == currentSessionId else { return }
        do {
            let count: PaginatedResponse<Message> = try await client.getPaginated(
                "/messages",
                query: ["session_id": sessionId, "$limit": "1"]
            )
            let serverTotal = count.total
            let lastIndex = messages.last?.index ?? 0

            // If server has more messages than we know about, fetch the new ones
            if serverTotal > messages.count + currentSkip {
                let newMessages: PaginatedResponse<Message> = try await client.getPaginated(
                    "/messages",
                    query: [
                        "session_id": sessionId,
                        "index[$gt]": "\(lastIndex)",
                        "$sort[index]": "1",
                        "$limit": "50",
                    ]
                )
                guard sessionId == self.currentSessionId else { return }
                let existingIds = Set(messages.map(\.messageId))
                let newOnly = newMessages.data.filter { !existingIds.contains($0.messageId) }
                if !newOnly.isEmpty {
                    messages.append(contentsOf: newOnly)
                    rebuildDisplayItems()
                    scrollToBottomToken += 1
                }
            }

            // Also refresh session state
            await loadSession(sessionId)
        } catch {
            // Non-fatal — polling failures are silent
        }
    }

    // MARK: - Permission Decision

    func approvePermission(requestId: String, taskId: String?, scope: PermissionScope) {
        guard let sessionId = currentSessionId else { return }
        Task {
            do {
                let decision = PermissionDecision(
                    requestId: requestId,
                    taskId: taskId,
                    allow: true,
                    reason: "Approved by user",
                    remember: scope != .once,
                    scope: scope,
                    decidedBy: userId
                )
                _ = try await client.postRaw("/sessions/\(sessionId)/permission-decision", body: decision)
            } catch {
                self.error = "Failed to approve: \(error.localizedDescription)"
            }
        }
    }

    func denyPermission(requestId: String, taskId: String?) {
        guard let sessionId = currentSessionId else { return }
        Task {
            do {
                let decision = PermissionDecision(
                    requestId: requestId,
                    taskId: taskId,
                    allow: false,
                    reason: "Denied by user",
                    remember: false,
                    scope: .once,
                    decidedBy: userId
                )
                _ = try await client.postRaw("/sessions/\(sessionId)/permission-decision", body: decision)
            } catch {
                self.error = "Failed to deny: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Input Response

    func submitInput(requestId: String, taskId: String?, answers: [String: String]) {
        guard let sessionId = currentSessionId else { return }
        Task {
            do {
                let response = InputResponse(
                    requestId: requestId,
                    taskId: taskId,
                    answers: answers,
                    respondedBy: userId
                )
                _ = try await client.postRaw("/sessions/\(sessionId)/input-response", body: response)
            } catch {
                self.error = "Failed to submit: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Display Items Builder

    func rebuildDisplayItems() {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else { return }
            _rebuildDisplayItemsNow()
        }
    }

    private func _rebuildDisplayItemsNow() {
        var items: [DisplayItem] = []

        // Group messages by task_id
        let taskMap = Dictionary(grouping: messages) { $0.taskId ?? "" }
        var handledTaskIds = Set<String>()

        for task in tasks {
            handledTaskIds.insert(task.taskId)
            items.append(.taskHeader(task))
            guard !collapsedTaskIds.contains(task.taskId) else { continue }
            let taskMessages = taskMap[task.taskId] ?? []
            items.append(contentsOf: taskMessages.map { .message($0) })
        }

        // Messages without a task
        let orphanMessages = messages.filter { msg in
            msg.taskId == nil || !handledTaskIds.contains(msg.taskId ?? "")
        }
        items.append(contentsOf: orphanMessages.map { .message($0) })

        // Active streaming messages
        let streamingIds = Set(messages.map(\.messageId))
        for (_, stream) in activeStreams where stream.sessionId == currentSessionId {
            if !streamingIds.contains(stream.messageId) {
                items.append(.streaming(stream))
            }
        }

        displayItems = items
    }

    // MARK: - Socket Handlers

    private func setupSocketHandlers() {
        socketService.onMessageCreated { [weak self] message in
            guard let self, message.sessionId == self.currentSessionId else { return }
            // Remove from streaming (handoff)
            self.activeStreams.removeValue(forKey: message.messageId)
            // Add to messages if not already there
            if !self.messages.contains(where: { $0.messageId == message.messageId }) {
                self.messages.append(message)
                self.rebuildDisplayItems()
                self.scrollToBottomToken += 1  // new message — scroll to bottom
            }
        }

        socketService.onMessagePatched { [weak self] message in
            guard let self, message.sessionId == self.currentSessionId else { return }
            if let idx = self.messages.firstIndex(where: { $0.messageId == message.messageId }) {
                self.messages[idx] = message
                self.rebuildDisplayItems()
            }
        }

        socketService.onTaskCreated { [weak self] task in
            guard let self, task.sessionId == self.currentSessionId else { return }
            if !self.tasks.contains(where: { $0.taskId == task.taskId }) {
                self.tasks.append(task)
                self.rebuildDisplayItems()
            }
        }

        socketService.onTaskPatched { [weak self] task in
            guard let self, task.sessionId == self.currentSessionId else { return }
            if let idx = self.tasks.firstIndex(where: { $0.taskId == task.taskId }) {
                self.tasks[idx] = task
                self.rebuildDisplayItems()
            }
        }

        socketService.onSessionPatched { [weak self] session in
            guard let self, session.sessionId == self.currentSessionId else { return }
            self.currentSession = session
            // Clear stale streams when session becomes idle (handles missed thinking:end)
            if session.status == .idle {
                self.streamingService.clearStreams(for: session.sessionId)
                self.activeStreams = self.streamingService.activeStreams
                self.rebuildDisplayItems()
            }
        }
    }

    // MARK: - State Helpers

    var connectionState: ConnectionState {
        socketService.connectionState
    }

    var isSessionPromptable: Bool {
        currentSession?.isPromptable ?? false
    }

    var sessionNeedsAttention: Bool {
        currentSession?.status.needsAttention ?? false
    }

    var firstPendingPermissionId: String? {
        for msg in messages {
            if case .permissionRequest(let perm) = msg.content, perm.isPending {
                return msg.messageId
            }
        }
        return nil
    }

    var firstPendingInputId: String? {
        for msg in messages {
            if case .inputRequest(let input) = msg.content, input.isPending {
                return msg.messageId
            }
        }
        return nil
    }

    var canStopSession: Bool {
        guard let session = currentSession else { return false }
        return session.status.isActive && !isStoppingSession
    }

    // MARK: - Streaming Handlers

    private func setupStreamingHandlers() {
        socketService.onStreamingStart = { [weak self] event in
            self?.streamingService.handleStreamingStart(event)
        }
        socketService.onStreamingChunk = { [weak self] event in
            self?.streamingService.handleStreamingChunk(event)
        }
        socketService.onStreamingEnd = { [weak self] event in
            self?.streamingService.handleStreamingEnd(event)
        }
        socketService.onStreamingError = { [weak self] event in
            self?.streamingService.handleStreamingError(event)
        }
        socketService.onThinkingStart = { [weak self] event in
            self?.streamingService.handleThinkingStart(event)
        }
        socketService.onThinkingChunk = { [weak self] event in
            self?.streamingService.handleThinkingChunk(event)
        }
        socketService.onThinkingEnd = { [weak self] event in
            self?.streamingService.handleThinkingEnd(event)
        }

        // When streams change, update activeStreams and rebuild display
        streamingService.onStreamsChanged = { [weak self] in
            guard let self else { return }
            self.activeStreams = self.streamingService.activeStreams
            self.rebuildDisplayItems()
        }

        // Also clear streaming buffer when a persisted message arrives
        socketService.onMessageCreated { [weak self] message in
            self?.streamingService.handleMessageCreated(messageId: message.messageId)
        }
    }
}
