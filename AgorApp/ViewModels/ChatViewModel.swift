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
    // Tracks whether user is scrolled near the bottom — new messages only auto-scroll when true
    var userIsNearBottom = true
    // Last time user was near bottom — grace period for layout changes
    var lastNearBottomTime: Date = .distantPast
    // Scroll to a specific message ID (for permission cards)
    var scrollToMessageId: String?
    var scrollToMessageInProgress = false

    // Track permission resolution for auto-scroll restoration
    private var lastResolvedPermissionTime: Date?

    private var rebuildTask: Task<Void, Never>?
    private var scrollDebounceTask: Task<Void, Never>?

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

    // Voice mode
    var voiceService: ContinuousVoiceService?
    private var lastSpokenMessageId: String?
    var voiceSessionId: String?
    private var voiceStreamBuffer = ""  // Accumulates streaming text for live TTS
    var voiceModeEnabled: Bool = false {
        didSet {
            if voiceModeEnabled {
                enableVoiceMode()
            } else {
                disableVoiceMode()
            }
        }
    }

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
        // Voice mode is NOT disabled on session switch — it continues running on voiceSessionId.
        // The floating button guides the user back to the voice session.

        if sessionId == currentSessionId {
            // Same session re-selected — do a soft refresh to pick up any missed events
            AppLogger.shared.log("[Chat] selectSession \(sessionId) (soft refresh)", level: .debug, category: "Chat")
            Task {
                await loadSession(sessionId)
                await loadTasks(sessionId)
                await checkForNewMessages(sessionId)
            }
            return
        }
        AppLogger.shared.log("[Chat] selectSession \(sessionId)", level: .info, category: "Chat")
        stopMessagePolling()
        currentSessionId = sessionId
        messages = []
        tasks = []
        displayItems = []
        activeStreams = [:]
        voiceStreamBuffer = ""
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
        // Re-enable auto-scroll on reconnect — scroll position tracking may be stale
        userIsNearBottom = true
        lastNearBottomTime = Date()
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
                // Proactively refresh in case socket events were missed
                try? await Task.sleep(for: .milliseconds(300))
                guard currentSessionId == sessionId else { return }
                AppLogger.shared.log("[Chat] sendPrompt: proactive refresh after send", level: .debug, category: "Chat")
                await loadSession(sessionId)
                await loadTasks(sessionId)
                await checkForNewMessages(sessionId)
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
                // Archive the current session via Socket.IO
                AppLogger.shared.log("[Chat] resetSession: archiving \(sessionId)", level: .info, category: "Chat")
                let _: Session = try await socketService.servicePatch(
                    service: "sessions",
                    id: sessionId,
                    data: ["archived": true]
                )

                // Create a new session on the same worktree via Socket.IO
                var createData: [String: Any] = [
                    "worktree_id": worktreeId,
                    "agentic_tool": agenticTool.rawValue,
                    "status": "idle"
                ]
                if let sessionTitle, !sessionTitle.isEmpty {
                    createData["title"] = sessionTitle
                }
                let newSession: Session = try await socketService.serviceCreate(
                    service: "sessions",
                    data: createData
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
        // Must schedule on main RunLoop — Timer.scheduledTimer called from a Swift Task
        // (cooperative thread pool) has no RunLoop and the timer never fires
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.messagePollingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                guard let self, let sessionId = self.currentSessionId else { return }
                Task { await self.checkForNewMessages(sessionId) }
            }
        }
    }

    func stopMessagePolling() {
        messagePollingTimer?.invalidate()
        messagePollingTimer = nil
    }

    private func checkForNewMessages(_ sessionId: String) async {
        guard sessionId == currentSessionId else { return }
        do {
            // Check for new tasks (user's prompt appears as a task header)
            let taskCount: PaginatedResponse<AgorTask> = try await client.getPaginated(
                "/tasks",
                query: ["session_id": sessionId, "$limit": "1"]
            )
            guard sessionId == currentSessionId else { return }
            if taskCount.total > tasks.count {
                await loadTasks(sessionId)
            }

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
                    requestScrollToBottom()
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
                lastResolvedPermissionTime = Date()
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
                lastResolvedPermissionTime = Date()
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
                lastResolvedPermissionTime = Date()
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
            let taskMessages = (taskMap[task.taskId] ?? []).sorted { $0.index < $1.index }
            items.append(contentsOf: taskMessages.map { .message($0) })
        }

        // Messages without a task
        let orphanMessages = messages.filter { msg in
            msg.taskId == nil || !handledTaskIds.contains(msg.taskId ?? "")
        }.sorted { $0.index < $1.index }
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

    /// Debounced scroll-to-bottom: coalesces rapid socket messages into one scroll
    private var scrollRequestCount = 0
    private func requestScrollToBottom() {
        if scrollToMessageInProgress {
            AppLogger.shared.log("[Scroll] requestScrollToBottom skipped — scrollToMessageInProgress=true", level: .debug, category: "Scroll")
            return
        }
        // Allow scroll if near bottom, OR if bottom marker was visible within last 2s.
        // The 2s grace period covers the LazyVStack layout race: when new items are appended,
        // the list expands and onDisappear fires on the bottom marker before the scroll runs.
        let recentlyNearBottom = Date().timeIntervalSince(lastNearBottomTime) < 2.0
        guard userIsNearBottom || recentlyNearBottom else {
            AppLogger.shared.log("[Scroll] requestScrollToBottom skipped — userIsNearBottom=false, lastNearBottom=\(Int(-lastNearBottomTime.timeIntervalSinceNow))s ago", level: .debug, category: "Scroll")
            return
        }
        scrollRequestCount += 1
        let requestNum = scrollRequestCount
        let wasPending = scrollDebounceTask != nil
        scrollDebounceTask?.cancel()
        AppLogger.shared.log("[Scroll] requestScrollToBottom #\(requestNum) queued (cancelled pending: \(wasPending))", level: .debug, category: "Scroll")
        scrollDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            AppLogger.shared.log("[Scroll] debounce fired → scrollToBottomToken (coalesced \(self.scrollRequestCount - requestNum + 1) requests)", level: .debug, category: "Scroll")
            self.scrollRequestCount = 0
            self.scrollToBottomToken += 1
        }
    }

    private func setupSocketHandlers() {
        socketService.onMessageCreated { [weak self] message in
            guard let self else { return }
            AppLogger.shared.log("[ChatVM] Received onMessageCreated: \(message.messageId.prefix(8)) session=\(message.sessionId)", level: .debug, category: "Chat")
            guard message.sessionId == self.currentSessionId else { 
                AppLogger.shared.log("[ChatVM] Ignoring message \(message.messageId.prefix(8)) - session mismatch (\(message.sessionId) != \(self.currentSessionId ?? "nil"))", level: .debug, category: "Chat")
                return 
            }
            // Remove from streaming (handoff)
            self.activeStreams.removeValue(forKey: message.messageId)
            // If permission was just resolved, restore auto-scroll on first new assistant message
            if let resolvedTime = lastResolvedPermissionTime,
               Date().timeIntervalSince(resolvedTime) < 5.0, // Within 5s window
               message.role == .assistant {
                AppLogger.shared.log("[Scroll] First message after permission → restoring userIsNearBottom", level: .debug, category: "Scroll")
                userIsNearBottom = true
                lastResolvedPermissionTime = nil
            }
            // Voice: speak text content immediately; fall back to tool-use phrase if no text
            if self.voiceModeEnabled, message.role == .assistant {
                if !self.voiceStreamBuffer.isEmpty {
                    // We were streaming-speaking — flush remaining buffer, skip re-speaking full message
                    let remaining = self.voiceStreamBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.voiceStreamBuffer = ""
                    if !remaining.isEmpty {
                        AppLogger.shared.log("[Voice] 💬 Flushing stream buffer (\(remaining.count) chars)", level: .info, category: "Voice")
                        self.voiceService?.speakStatus(remaining)
                    }
                    self.lastSpokenMessageId = message.messageId
                } else {
                    let text = self.extractTextFromMessage(message)
                    if !text.isEmpty {
                        let spokenText = text.count > 500 ? self.summarizeText(text) : text
                        AppLogger.shared.log("[Voice] 💬 Speaking assistant message (\(text.count) chars)", level: .info, category: "Voice")
                        self.voiceService?.speakMessage(spokenText)
                        self.lastSpokenMessageId = message.messageId
                    } else if case .blocks(let blocks) = message.content {
                        for block in blocks {
                            if case .toolUse(let tool) = block {
                                let phrase = self.voicePhrase(for: tool.name)
                                AppLogger.shared.log("[Voice] 🔧 Tool use detected: \(tool.name) → speaking '\(phrase)'", level: .info, category: "Voice")
                                self.voiceService?.speakStatus(phrase)
                                break
                            }
                        }
                    }
                }
            }

            // Add to messages if not already there
            if !self.messages.contains(where: { $0.messageId == message.messageId }) {
                self.messages.append(message)
                self.rebuildDisplayItems()
                AppLogger.shared.log("[Scroll] onMessageCreated → requestScrollToBottom (msg: \(message.messageId.prefix(8)), total: \(self.messages.count))", level: .debug, category: "Scroll")
                self.requestScrollToBottom()
            } else {
                AppLogger.shared.log("[ChatVM] Message \(message.messageId.prefix(8)) already exists in local list", level: .debug, category: "Chat")
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
            let oldStatus = self.currentSession?.status
            self.currentSession = session
            AppLogger.shared.log("[Scroll] onSessionPatched: \(oldStatus?.rawValue ?? "nil") → \(session.status.rawValue)", level: .debug, category: "Scroll")

            // Restore auto-scroll after permission resolution
            if let resolvedTime = lastResolvedPermissionTime,
               Date().timeIntervalSince(resolvedTime) < 2.0, // Within 2s of resolution
               (oldStatus == .awaitingPermission || oldStatus == .awaitingInput),
               session.status == .running {
                AppLogger.shared.log("[Scroll] Permission resolved → restoring userIsNearBottom", level: .debug, category: "Scroll")
                userIsNearBottom = true
                lastResolvedPermissionTime = nil
            }

            // Voice mode: speak status changes
            if voiceModeEnabled && oldStatus != session.status {
                handleVoiceStatusChange(from: oldStatus, to: session.status)
            }

            // Clear stale streams when session becomes idle (handles missed thinking:end)
            if session.status == .idle {
                self.streamingService.clearStreams(for: session.sessionId)
                self.activeStreams = self.streamingService.activeStreams
                self.rebuildDisplayItems()
            }
            // Auto-scroll to current pending permission/input card when session needs attention
            if session.status == .awaitingPermission || session.status == .awaitingInput {
                let permId = self.currentPendingPermissionId
                let inputId = self.currentPendingInputId
                AppLogger.shared.log("[Scroll] session needs attention — permId: \(permId?.prefix(8) ?? "nil"), inputId: \(inputId?.prefix(8) ?? "nil"), msgs: \(self.messages.count)", level: .debug, category: "Scroll")
                if let msgId = permId ?? inputId {
                    self.scrollToMessageInProgress = true
                    self.scrollToMessageId = "msg-\(msgId)"
                    AppLogger.shared.log("[Scroll] → scrollToMessageId = msg-\(msgId.prefix(8))", level: .debug, category: "Scroll")
                } else {
                    AppLogger.shared.log("[Scroll] ⚠️ no pending permission/input message found in \(self.messages.count) messages", level: .warning, category: "Scroll")
                }
            }

            // Update voice listening state
            updateVoiceListening()
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

    var currentPendingPermissionId: String? {
        // Find LAST pending permission (highest index = most recent)
        for msg in messages.reversed() {
            if case .permissionRequest(let perm) = msg.content, perm.isPending {
                return msg.messageId
            }
        }
        return nil
    }

    var currentPendingInputId: String? {
        // Find LAST pending input (highest index = most recent)
        for msg in messages.reversed() {
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
            self?.handleStreamingChunkForVoice(event)
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

    // MARK: - Voice Mode

    func enableVoiceMode() {
        guard voiceService == nil else { return }

        voiceSessionId = currentSessionId
        UIApplication.shared.isIdleTimerDisabled = true

        let service = ContinuousVoiceService()
        service.onTranscription = { [weak self] text in
            self?.handleVoiceInput(text)
        }
        service.onTTSFinished = { [weak self] in
            Task { @MainActor in
                self?.updateVoiceListening()
            }
        }

        voiceService = service

        // Initialize transcription service in background
        Task {
            do {
                try await service.transcription.initialize()
                try service.startListening()
                AppLogger.shared.log("[Voice] Voice mode enabled", level: .info, category: "Voice")
                // If agent is already working when voice is opened, announce it immediately
                await MainActor.run {
                    if let status = self.currentSession?.status, status != .idle {
                        self.handleVoiceStatusChange(from: nil, to: status)
                    }
                    self.updateVoiceListening()
                }
            } catch {
                AppLogger.shared.log("[Voice] Failed to enable voice mode: \(error.localizedDescription)", level: .error, category: "Voice")
                await MainActor.run {
                    UIApplication.shared.isIdleTimerDisabled = false
                    self.error = "Voice mode failed: \(error.localizedDescription)"
                    self.voiceService = nil
                    self.voiceModeEnabled = false
                }
            }
        }
    }

    func disableVoiceMode() {
        UIApplication.shared.isIdleTimerDisabled = false
        voiceService?.stopListening()
        voiceService = nil
        voiceSessionId = nil
        voiceStreamBuffer = ""
        AppLogger.shared.log("[Voice] Voice mode disabled", level: .info, category: "Voice")
    }

    // MARK: - Streaming TTS

    private func handleStreamingChunkForVoice(_ event: StreamingChunkEvent) {
        guard voiceModeEnabled,
              event.sessionId == (voiceSessionId ?? currentSessionId) else { return }

        voiceStreamBuffer += event.chunk
        speakBufferedSentences()
    }

    /// Extracts and speaks any complete sentences from the stream buffer,
    /// leaving incomplete trailing text in the buffer for the next chunk.
    private func speakBufferedSentences() {
        var speakUpTo = voiceStreamBuffer.startIndex
        var i = voiceStreamBuffer.startIndex

        while i < voiceStreamBuffer.endIndex {
            let char = voiceStreamBuffer[i]
            let next = voiceStreamBuffer.index(after: i)

            if char == "." || char == "!" || char == "?" {
                // Sentence end: speak if followed by whitespace or end-of-buffer
                if next == voiceStreamBuffer.endIndex || voiceStreamBuffer[next].isWhitespace {
                    speakUpTo = next
                }
            } else if char == "\n", next < voiceStreamBuffer.endIndex, voiceStreamBuffer[next] == "\n" {
                // Paragraph break
                speakUpTo = voiceStreamBuffer.index(after: next)
            }

            i = next
        }

        guard speakUpTo > voiceStreamBuffer.startIndex else { return }

        let toSpeak = String(voiceStreamBuffer[..<speakUpTo])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        voiceStreamBuffer = String(voiceStreamBuffer[speakUpTo...])

        // Skip pure code blocks (lines starting with 4+ spaces or backticks)
        let isCode = toSpeak.hasPrefix("    ") || toSpeak.hasPrefix("\t") || toSpeak.hasPrefix("```")
        guard !isCode, !toSpeak.isEmpty else { return }

        AppLogger.shared.log("[Voice] 🔊 Stream speak: \(toSpeak.prefix(60))", level: .debug, category: "Voice")
        voiceService?.speakStreamChunk(toSpeak)
    }

    private func handleVoiceInput(_ text: String) {
        // Text appears for 5s, then auto-sends if not edited
        promptText = text

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(5000)) // Give user time to review
            if promptText == text { // User didn't edit
                sendPrompt()
            }
        }
    }

    private func updateVoiceListening() {
        guard let voice = voiceService else { return }

        if currentSession?.status == .idle && isSessionPromptable {
            if voice.state == .disabled {
                // Fresh start
                do {
                    try voice.startListening()
                } catch {
                    AppLogger.shared.log("[Voice] Failed to start listening: \(error.localizedDescription)", level: .error, category: "Voice")
                }
            } else if voice.isPaused && !voice.isTTSSpeaking {
                // Resume after agent finished — wait for TTS to finish first
                do {
                    try voice.resumeListening()
                } catch {
                    AppLogger.shared.log("[Voice] Failed to resume listening: \(error.localizedDescription)", level: .error, category: "Voice")
                }
            }
        } else if currentSession?.status != .idle {
            // Agent is running — pause VAD without disrupting TTS or showing disabled state
            if !voice.isPaused && voice.state != .disabled {
                voice.pauseListening()
            }
        }
    }

    private func handleVoiceStatusChange(from oldStatus: SessionStatus?, to newStatus: SessionStatus) {
        guard voiceModeEnabled else { return }

        AppLogger.shared.log("[Voice] 📊 Session status change: \(oldStatus?.rawValue ?? "nil") → \(newStatus.rawValue)", level: .info, category: "Voice")

        switch newStatus {
        case .running:
            let phrase = workingStatusPhrase()
            AppLogger.shared.log("[Voice] 🤔 Agent started running - speaking '\(phrase)'", level: .info, category: "Voice")
            voiceService?.speakStatus(phrase)
        case .idle:
            // Check if there's a new final message
            if hasNewAssistantMessage(since: oldStatus) {
                AppLogger.shared.log("[Voice] ✅ Agent finished with new message - speaking final message", level: .info, category: "Voice")
                speakFinalMessage()
            } else if oldStatus == .running {
                // Went from running → idle without new message (aborted/cancelled)
                AppLogger.shared.log("[Voice] 🛑 Agent stopped without message - speaking 'Stopped'", level: .info, category: "Voice")
                voiceService?.speakStatus("Stopped")
            }
        case .awaitingPermission:
            AppLogger.shared.log("[Voice] 🔐 Agent awaiting permission - speaking 'I need permission'", level: .info, category: "Voice")
            voiceService?.speakStatus("I need permission")
        case .awaitingInput:
            AppLogger.shared.log("[Voice] ⌨️ Agent awaiting input - speaking 'I need input'", level: .info, category: "Voice")
            voiceService?.speakStatus("I need input")
        default:
            AppLogger.shared.log("[Voice] ℹ️ Unhandled status: \(newStatus.rawValue)", level: .debug, category: "Voice")
            break
        }
    }

    private func hasNewAssistantMessage(since oldStatus: SessionStatus?) -> Bool {
        // Check if last message is from assistant and relatively recent
        guard let lastMessage = messages.last,
              lastMessage.role == .assistant else {
            return false
        }

        // If we have a recent assistant message, consider it new
        return true
    }

    private func speakFinalMessage() {
        guard voiceModeEnabled, let lastMessage = messages.last else { return }

        // Already spoken when it arrived via onMessageCreated — don't double-speak
        if lastMessage.messageId == lastSpokenMessageId {
            AppLogger.shared.log("[Voice] ⏭️ Final message already spoken — skipping", level: .info, category: "Voice")
            lastSpokenMessageId = nil
            return
        }

        let text = extractTextFromMessage(lastMessage)
        guard !text.isEmpty else { return }

        let spokenText = text.count > 500 ? summarizeText(text) : text
        lastSpokenMessageId = lastMessage.messageId
        voiceService?.speakFinalMessage(spokenText)
    }

    private func extractTextFromMessage(_ message: Message) -> String {
        // Parse message.content for text blocks only
        switch message.content {
        case .text(let text):
            return text
        case .blocks(let blocks):
            var textParts: [String] = []
            for block in blocks {
                if case .text(let textBlock) = block {
                    textParts.append(textBlock.text)
                }
            }
            return textParts.joined(separator: " ")
        default:
            return ""
        }
    }

    private func summarizeText(_ text: String) -> String {
        if text.count <= 400 {
            return text
        }
        return String(text.prefix(400)) + "..."
    }

    private func workingStatusPhrase() -> String {
        return "Working"
    }

    private func voicePhrase(for toolName: String) -> String {
        let name = toolName.lowercased()
        if name.contains("read")                                    { return "Reading" }
        if name.contains("write")                                   { return "Writing" }
        if name.contains("edit")                                    { return "Editing" }
        if name.contains("bash") || name.contains("exec") || name.contains("run") { return "Running command" }
        if name.contains("grep") || name.contains("search")        { return "Searching" }
        if name.contains("glob") || name.contains("list")          { return "Listing files" }
        if name.contains("web")                                     { return "Searching web" }
        if name.contains("agent") || name.contains("spawn")        { return "Spawning agent" }
        if name.contains("todo")                                    { return "Updating tasks" }
        return "Working"
    }
}
