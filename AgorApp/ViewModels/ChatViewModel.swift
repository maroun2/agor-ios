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
    var promptText: String = ""

    // Streaming
    var activeStreams: [String: StreamingMessage] = [:]

    // Pagination
    var hasMore = true
    private var currentSkip = 0
    private let pageSize = 50

    // Dependencies
    var userId: String
    private let client: AgorClient
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
        currentSessionId = sessionId
        messages = []
        tasks = []
        displayItems = []
        activeStreams = [:]
        currentSkip = 0
        hasMore = true
        error = nil

        Task {
            await loadSession(sessionId)
            await loadTasks(sessionId)
            await loadMessages(sessionId)
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
                rebuildDisplayItems()
            }
        } catch {
            // Non-fatal
        }
    }

    func loadMessages(_ sessionId: String) async {
        isLoadingMessages = true
        do {
            let response: PaginatedResponse<Message> = try await client.getPaginated(
                "/messages",
                query: [
                    "session_id": sessionId,
                    "$sort[index]": "1",
                    "$limit": "\(pageSize)",
                    "$skip": "\(currentSkip)",
                ]
            )
            if currentSessionId == sessionId {
                if currentSkip == 0 {
                    messages = response.data
                } else {
                    messages.append(contentsOf: response.data)
                }
                hasMore = response.total > messages.count
                currentSkip = messages.count
                rebuildDisplayItems()
            }
        } catch {
            self.error = "Failed to load messages"
        }
        isLoadingMessages = false
    }

    func loadMore() async {
        guard hasMore, !isLoadingMessages, let sessionId = currentSessionId else { return }
        await loadMessages(sessionId)
    }

    // MARK: - Send Prompt

    func sendPrompt() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let sessionId = currentSessionId else { return }
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
                self.error = "Failed to send prompt: \(error.localizedDescription)"
            }
            isSendingPrompt = false
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
        var items: [DisplayItem] = []

        // Group messages by task_id
        let taskMap = Dictionary(grouping: messages) { $0.taskId ?? "" }
        var handledTaskIds = Set<String>()

        for task in tasks {
            handledTaskIds.insert(task.taskId)
            items.append(.taskHeader(task))
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
        }
    }

    // MARK: - State Helpers

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
