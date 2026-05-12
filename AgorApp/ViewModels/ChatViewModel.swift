import Foundation
import SwiftUI

// MARK: - Display Item (union of message types for the list)

enum DisplayItem: Identifiable {
    case taskHeader(AgorTask)
    case message(Message)
    case streaming(StreamingMessage)
    case olderTasksBanner(Int) // count of hidden older tasks
    case taskError(String, String) // (taskId, error text) — inline error under failed task

    var id: String {
        switch self {
        case .taskHeader(let task): "task-\(task.taskId)"
        case .message(let msg): "msg-\(msg.messageId)"
        case .streaming(let s): "stream-\(s.messageId)"
        case .olderTasksBanner: "older-tasks-banner"
        case .taskError(let taskId, _): "error-\(taskId)"
        }
    }

    var sessionId: String {
        switch self {
        case .taskHeader(let t): t.sessionId
        case .message(let m): m.sessionId
        case .streaming(let s): s.sessionId
        case .olderTasksBanner: ""
        case .taskError: ""
        }
    }
}

// MARK: - Chat ViewModel

@Observable
@MainActor
final class ChatViewModel {
    var currentSessionId: String?
    var currentSession: Session?
    // Task-centric message storage (matches web UI's messagesByTask map)
    var messagesByTask: [String: [Message]] = [:]
    var loadedTaskIds: Set<String> = []
    // Fallback flat array for sessions without server tasks (virtual-task mode)
    var virtualMessages: [Message] = []
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
            if sessionId == voiceSessionId, voicePendingPromptText != nil {
                voicePendingPromptText = promptText.isEmpty ? nil : promptText
            }
            if promptText.isEmpty {
                UserDefaults.standard.removeObject(forKey: Self.draftKeyPrefix + sessionId)
            } else {
                UserDefaults.standard.set(promptText, forKey: Self.draftKeyPrefix + sessionId)
            }
        }
    }

    // Collapsed tasks
    var collapsedTaskIds: Set<String> = []
    // Per-task error messages (shown inline in chat under failed task headers)
    var taskErrors: [String: String] = [:]
    // How many recent tasks to show (older ones hidden behind "Show N older" banner)
    private let defaultVisibleTaskLimit = 20
    var visibleTaskLimit = 20

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
            // Expanding — load messages for this task
            collapsedTaskIds.remove(taskId)
            _rebuildDisplayItemsNow()
            if !taskId.hasPrefix("virtual-") {
                Task { await loadTaskMessages(taskId) }
            }
        } else {
            // Collapsing — unload messages to free memory (matches web UI)
            collapsedTaskIds.insert(taskId)
            if !taskId.hasPrefix("virtual-") {
                unloadTaskMessages(taskId)
            }
            _rebuildDisplayItemsNow()
        }
    }

    /// Reveal more older task headers (doubles the visible limit each tap)
    func showOlderTasks() {
        visibleTaskLimit = min(visibleTaskLimit + defaultVisibleTaskLimit, tasks.count)
        rebuildDisplayItems()
    }

    // Streaming
    var activeStreams: [String: StreamingMessage] = [:]

    // Polling timer (tasks + session state only, NOT messages)
    private var pollingTimer: Timer?

    // Convenience: all messages across loaded tasks (for voice, permissions, etc.)
    var allMessages: [Message] {
        if !tasks.isEmpty {
            return messagesByTask.values.flatMap { $0 }.sorted { $0.index < $1.index }
        } else {
            return virtualMessages.sorted { $0.index < $1.index }
        }
    }

    // Voice mode
    var voiceService: ContinuousVoiceService?
    private var lastSpokenMessageId: String?
    var voiceSessionId: String?
    private var voiceSession: Session?
    private var voiceLastAssistantMessage: Message?
    private var voicePendingPromptText: String?

    // VAD config — persisted to UserDefaults as JSON; applied to voiceService on change.
    // @ObservationIgnored: no view reads this for display, so it must not enter AttributeGraph.
    private static let vadConfigKey = "agor.vadConfig"
    @ObservationIgnored
    var vadConfig: VADConfig = VADConfig() {
        didSet {
            guard vadConfig != oldValue else { return }
            if let data = try? JSONEncoder().encode(vadConfig) {
                UserDefaults.standard.set(data, forKey: Self.vadConfigKey)
            }
            voiceService?.vadConfig = vadConfig
        }
    }
    private var voiceStreamBuffer = ""          // Accumulates streaming text for live TTS
    private var voiceDidStreamCurrentMessage = false  // True if any chunk was spoken for current turn
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
        // Restore persisted VAD config (didSet not called in init, so no side effects)
        if let data = UserDefaults.standard.data(forKey: Self.vadConfigKey),
           let decoded = try? JSONDecoder().decode(VADConfig.self, from: data) {
            vadConfig = decoded
        }
        setupSocketHandlers()
        setupStreamingHandlers()
    }

    // MARK: - Session Selection

    func selectSession(_ sessionId: String) {
        // Voice mode stays active across session switches, but only the owning session
        // should render inline voice UI or receive voice-driven prompt updates.

        if sessionId == currentSessionId {
            // Same session re-selected — soft refresh
            AppLogger.shared.log("[Chat] selectSession \(sessionId) (soft refresh)", level: .debug, category: "Chat")
            Task {
                await loadSession(sessionId)
                await loadTasks(sessionId)
                // Reload messages for the last (expanded) task
                if let lastTaskId = tasks.last?.taskId, !collapsedTaskIds.contains(lastTaskId) {
                    await loadTaskMessages(lastTaskId)
                }
            }
            return
        }
        AppLogger.shared.log("[Chat] selectSession \(sessionId)", level: .info, category: "Chat")
        stopPolling()
        currentSessionId = sessionId
        messagesByTask = [:]
        loadedTaskIds = []
        virtualMessages = []
        tasks = []
        displayItems = []
        activeStreams = [:]
        voiceStreamBuffer = ""
        voiceDidStreamCurrentMessage = false
        collapsedTaskIds = []
        taskErrors = [:]
        visibleTaskLimit = defaultVisibleTaskLimit
        error = nil
        // Restore draft for this session (set directly to avoid didSet writing back before session is set)
        promptText = draftText(for: sessionId)

        Task {
            await loadSession(sessionId)
            // Mark as viewed if server flagged ready_for_prompt
            if currentSession?.readyForPrompt == true {
                await markSessionViewed(sessionId)
            }
            await loadTasks(sessionId)
            // Load messages for last (expanded) task — matches web UI lazy loading
            if let lastTaskId = tasks.last?.taskId {
                await loadTaskMessages(lastTaskId)
            } else {
                // No tasks — use virtual-task mode with session-based loading
                await loadVirtualMessages(sessionId)
            }
            startPolling()
            scrollToBottomToken += 1
        }
    }

    func refreshCurrentSession() {
        guard let sessionId = currentSessionId else { return }
        stopPolling()
        // Clear stale streaming state (e.g., missed thinking:end while backgrounded)
        streamingService.clearStreams(for: sessionId)
        activeStreams = streamingService.activeStreams
        // Clear stale voice stream buffer so TTS doesn't speak old content on resume
        voiceStreamBuffer = ""
        voiceDidStreamCurrentMessage = false
        // Re-enable auto-scroll on reconnect — scroll position tracking may be stale
        userIsNearBottom = true
        lastNearBottomTime = Date()
        Task {
            await loadSession(sessionId)
            await MainActor.run { updateVoiceListening() }
            await loadTasks(sessionId)
            // Reload messages for all currently-loaded tasks
            for taskId in loadedTaskIds {
                await loadTaskMessages(taskId)
            }
            // If virtual-task mode, reload
            if tasks.isEmpty {
                await loadVirtualMessages(sessionId)
            }
            startPolling()
        }
    }

    // MARK: - Load Data

    private func loadSession(_ sessionId: String) async {
        do {
            let session: Session = try await client.get("/sessions/\(sessionId)")
            if session.sessionId == voiceSessionId {
                voiceSession = session
            }
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
                // Merge: keep locally-added tasks (from socket events) not yet confirmed by server.
                // This prevents a race where loadTasks runs before the server has persisted a task
                // that onTaskCreated already added to the local list.
                let serverIds = Set(response.data.map(\.taskId))
                let unconfirmed = tasks.filter { !serverIds.contains($0.taskId) }
                let merged = response.data + unconfirmed
                tasks = merged
                AppLogger.shared.log("[Chat] loadTasks: \(response.data.count) from server + \(unconfirmed.count) unconfirmed local", level: .debug, category: "Chat")
                // Collapse all real tasks except the last one; preserve any virtual task collapse state.
                let lastId = merged.last?.taskId
                let newCollapsed = Set(merged.compactMap { $0.taskId != lastId ? $0.taskId : nil })
                let virtualCollapsed = collapsedTaskIds.filter { $0.hasPrefix("virtual-") }
                collapsedTaskIds = newCollapsed.union(virtualCollapsed)
                rebuildDisplayItems()
            }
        } catch {
            // Non-fatal
        }
    }

    // MARK: - Task-Centric Message Loading (matches web UI)

    /// Load messages for a specific task by task_id.
    /// Web UI equivalent: ReactiveSessionHandle.loadTaskMessages()
    func loadTaskMessages(_ taskId: String) async {
        guard let sessionId = currentSessionId else { return }
        // Skip virtual task IDs
        guard !taskId.hasPrefix("virtual-") else { return }

        isLoadingMessages = true
        do {
            let response: PaginatedResponse<Message> = try await client.getPaginated(
                "/messages",
                query: [
                    "task_id": taskId,
                    "$sort[index]": "1",
                    "$limit": "200",
                ]
            )
            guard currentSessionId == sessionId else { return }
            messagesByTask[taskId] = response.data.sorted { $0.index < $1.index }
            loadedTaskIds.insert(taskId)
            AppLogger.shared.log("[Chat] loadTaskMessages: \(response.data.count) msgs for task \(taskId.prefix(8))", level: .debug, category: "Chat")
            rebuildDisplayItems()
        } catch {
            AppLogger.shared.log("[Chat] loadTaskMessages ERROR: \(error.localizedDescription)", level: .error, category: "Chat")
        }
        isLoadingMessages = false
    }

    /// Unload messages for a collapsed task to free memory.
    /// Web UI equivalent: ReactiveSessionHandle.unloadTaskMessages()
    func unloadTaskMessages(_ taskId: String) {
        messagesByTask.removeValue(forKey: taskId)
        loadedTaskIds.remove(taskId)
    }

    /// Load messages for virtual-task mode (sessions without server tasks).
    /// Uses session_id query with $skip/$limit (the only operators the backend supports).
    private func loadVirtualMessages(_ sessionId: String) async {
        isLoadingMessages = true
        do {
            // Get total to jump to last page
            let count: PaginatedResponse<Message> = try await client.getPaginated(
                "/messages",
                query: ["session_id": sessionId, "$limit": "1"]
            )
            let total = count.total
            let pageSize = 50
            let startSkip = max(0, total - pageSize)
            let response: PaginatedResponse<Message> = try await client.getPaginated(
                "/messages",
                query: [
                    "session_id": sessionId,
                    "$limit": "\(pageSize)",
                    "$skip": "\(startSkip)",
                ]
            )
            guard currentSessionId == sessionId else { return }
            virtualMessages = response.data.sorted { $0.index < $1.index }
            AppLogger.shared.log("[Chat] loadVirtualMessages: \(response.data.count) msgs loaded", level: .debug, category: "Chat")
            initVirtualTaskCollapse()
            rebuildDisplayItems()
        } catch {
            AppLogger.shared.log("[Chat] loadVirtualMessages ERROR: \(error.localizedDescription)", level: .error, category: "Chat")
            self.error = "Failed to load messages"
        }
        isLoadingMessages = false
    }

    // MARK: - Send Prompt

    func sendPrompt() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let sessionId = currentSessionId else { return }
        AppLogger.shared.log("[Chat] sendPrompt to \(sessionId) (\(text.count) chars)", level: .debug, category: "Chat")
        if sessionId == voiceSessionId {
            voicePendingPromptText = nil
        }
        promptText = ""
        sendPrompt(to: sessionId, text: text, showSendingState: true)
    }

    /// Server response shape for prompt endpoint
    private struct PromptResponse: Codable {
        let success: Bool?
        let queued: Bool?
        let queue_position: Int?
        // Server may also return task/session info — we only need these fields
    }

    private func sendPrompt(to sessionId: String, text: String, showSendingState: Bool) {
        if showSendingState {
            isSendingPrompt = true
        }
        Task {
            do {
                struct PromptBody: Codable {
                    let prompt: String
                }
                let responseData = try await client.postRaw(
                    "/sessions/\(sessionId)/prompt",
                    body: PromptBody(prompt: text)
                )

                // Parse response to detect queued vs immediate execution
                if let parsed = try? JSONDecoder.agor.decode(PromptResponse.self, from: responseData),
                   parsed.queued == true {
                    let pos = parsed.queue_position ?? 0
                    AppLogger.shared.log("[Chat] sendPrompt: queued at position \(pos)", level: .info, category: "Chat")
                    self.error = "Prompt queued (position \(pos)) — session is busy"
                }

                // Proactively refresh tasks in case socket events were missed
                try? await Task.sleep(for: .milliseconds(300))
                if currentSessionId == sessionId {
                    AppLogger.shared.log("[Chat] sendPrompt: proactive refresh after send", level: .debug, category: "Chat")
                    await loadSession(sessionId)
                    await loadTasks(sessionId)
                    // Load messages for the new (last) task
                    if let lastTaskId = self.tasks.last?.taskId {
                        await loadTaskMessages(lastTaskId)
                    }
                } else if voiceSessionId == sessionId {
                    await loadSession(sessionId)
                }
            } catch {
                AppLogger.shared.log("[Chat] sendPrompt ERROR: \(error.localizedDescription)", level: .error, category: "Chat")
                self.error = "Failed to send prompt: \(error.localizedDescription)"
            }
            if showSendingState {
                isSendingPrompt = false
            }
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

    func uploadCrashLog() {
        guard let (data, fileName) = CrashLogService.shared.latestCrashLog() else { return }
        let mimeType = fileName.hasSuffix(".json") ? "application/json" : "text/plain"
        uploadAndInsertReference(fileData: data, fileName: fileName, mimeType: mimeType)
        CrashLogService.shared.clearCrashLogs()
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
        let unixUsername = session.unixUsername

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
                if let unixUsername {
                    createData["unix_username"] = unixUsername
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

    // MARK: - Polling (tasks + session state only)
    // Messages arrive via socket events — no message polling needed.
    // The backend ignores index[$gt] and $sort when session_id is present,
    // so message polling was fundamentally broken. Web UI also uses socket-only.

    func startPolling() {
        stopPolling()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pollingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                guard let self, let sessionId = self.currentSessionId else { return }
                Task { await self.pollForUpdates(sessionId) }
            }
        }
    }

    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func pollForUpdates(_ sessionId: String) async {
        guard sessionId == currentSessionId else { return }
        do {
            // Check for new tasks
            let taskCount: PaginatedResponse<AgorTask> = try await client.getPaginated(
                "/tasks",
                query: ["session_id": sessionId, "$limit": "1"]
            )
            guard sessionId == currentSessionId else { return }
            if taskCount.total > tasks.count {
                await loadTasks(sessionId)
                // Auto-load messages for the new last task
                if let lastTaskId = tasks.last?.taskId, !collapsedTaskIds.contains(lastTaskId) {
                    await loadTaskMessages(lastTaskId)
                }
            }

            // Refresh session state
            await loadSession(sessionId)
        } catch {
            // Non-fatal
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

        if tasks.isEmpty && !virtualMessages.isEmpty {
            // Virtual task mode: no server-managed tasks — group by user message turns.
            let sorted = virtualMessages.sorted { $0.index < $1.index }
            var userMsgIndices: [Int] = []
            for (i, msg) in sorted.enumerated() {
                if msg.role == .user { userMsgIndices.append(i) }
            }

            if userMsgIndices.isEmpty {
                items.append(contentsOf: sorted.map { .message($0) })
            } else {
                // Apply visibility limit to virtual tasks too
                let totalTurns = userMsgIndices.count
                let visibleStartTurn = max(0, totalTurns - visibleTaskLimit)
                let hiddenVirtualCount = visibleStartTurn

                if hiddenVirtualCount > 0 {
                    items.append(.olderTasksBanner(hiddenVirtualCount))
                } else {
                    // Show pre-first-user messages only when all turns visible
                    let firstIdx = userMsgIndices[0]
                    if firstIdx > 0 {
                        items.append(contentsOf: sorted[0..<firstIdx].map { .message($0) })
                    }
                }

                for turnIdx in visibleStartTurn..<totalTurns {
                    let userMsgIdx = userMsgIndices[turnIdx]
                    let userMsg = sorted[userMsgIdx]
                    let virtualId = "virtual-\(userMsg.messageId)"
                    let nextIdx = (turnIdx + 1 < totalTurns) ? userMsgIndices[turnIdx + 1] : sorted.count

                    let promptText: String
                    switch userMsg.content {
                    case .text(let t): promptText = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    default: promptText = userMsg.contentPreview.isEmpty ? "Message" : userMsg.contentPreview
                    }

                    let virtualTask = AgorTask(
                        taskId: virtualId,
                        sessionId: userMsg.sessionId,
                        createdBy: "",
                        fullPrompt: promptText.isEmpty ? "Message" : promptText,
                        description: nil,
                        status: .completed,
                        firstMessageIndex: userMsg.index,
                        lastMessageIndex: nil,
                        toolUseCount: nil,
                        gitState: nil,
                        durationMs: nil,
                        model: nil,
                        normalizedSdkResponse: nil,
                        createdAt: userMsg.timestamp,
                        startedAt: nil,
                        completedAt: nil
                    )

                    items.append(.taskHeader(virtualTask))
                    if !collapsedTaskIds.contains(virtualId) {
                        items.append(contentsOf: sorted[userMsgIdx..<nextIdx].map { .message($0) })
                    }
                }
            }
        } else if !tasks.isEmpty {
            // Normal mode: task-centric display matching web UI.
            // Hide old task headers entirely when there are many tasks.
            let visibleTasks: ArraySlice<AgorTask>
            let hiddenCount: Int
            if tasks.count > visibleTaskLimit {
                hiddenCount = tasks.count - visibleTaskLimit
                visibleTasks = tasks.suffix(visibleTaskLimit)
            } else {
                hiddenCount = 0
                visibleTasks = tasks[...]
            }

            if hiddenCount > 0 {
                items.append(.olderTasksBanner(hiddenCount))
            }

            for task in visibleTasks {
                items.append(.taskHeader(task))
                if let errorText = taskErrors[task.taskId] {
                    items.append(.taskError(task.taskId, errorText))
                }
                guard !collapsedTaskIds.contains(task.taskId) else { continue }
                let taskMessages = (messagesByTask[task.taskId] ?? []).sorted { $0.index < $1.index }
                items.append(contentsOf: taskMessages.map { .message($0) })
            }
        }

        // Active streaming messages
        let allMsgIds = Set(allMessages.map(\.messageId))
        for (_, stream) in activeStreams where stream.sessionId == currentSessionId {
            if !allMsgIds.contains(stream.messageId) {
                items.append(.streaming(stream))
            }
        }

        displayItems = items
    }

    private func initVirtualTaskCollapse() {
        let userMsgs = virtualMessages.filter { $0.role == .user }.sorted { $0.index < $1.index }
        guard userMsgs.count > 1 else { return }
        for msg in userMsgs.dropLast() {
            collapsedTaskIds.insert("virtual-\(msg.messageId)")
        }
        if let last = userMsgs.last {
            collapsedTaskIds.remove("virtual-\(last.messageId)")
        }
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
            AppLogger.shared.log("[ChatVM] onMessageCreated: \(message.messageId.prefix(8)) taskId=\(message.taskId?.prefix(8) ?? "nil") role=\(message.role.rawValue)", level: .debug, category: "Chat")
            self.handleVoiceMessageCreated(message)
            guard message.sessionId == self.currentSessionId else { return }
            // Remove from streaming (handoff)
            self.activeStreams.removeValue(forKey: message.messageId)
            // Restore auto-scroll after permission resolution
            if let resolvedTime = lastResolvedPermissionTime,
               Date().timeIntervalSince(resolvedTime) < 5.0,
               message.role == .assistant {
                userIsNearBottom = true
                lastResolvedPermissionTime = nil
            }

            if self.tasks.isEmpty {
                // Virtual-task mode: append to virtualMessages
                guard !self.virtualMessages.contains(where: { $0.messageId == message.messageId }) else { return }
                if message.role == .user,
                   let prevLastUser = self.virtualMessages.filter({ $0.role == .user }).max(by: { $0.index < $1.index }) {
                    self.collapsedTaskIds.insert("virtual-\(prevLastUser.messageId)")
                }
                self.virtualMessages.append(message)
                self.rebuildDisplayItems()
                self.requestScrollToBottom()
            } else {
                // Task-centric mode: only track if task is loaded (matches web UI)
                guard let taskId = message.taskId else {
                    AppLogger.shared.log("[ChatVM] Ignoring null-taskId message \(message.messageId.prefix(8))", level: .debug, category: "Chat")
                    return
                }
                guard self.loadedTaskIds.contains(taskId) else {
                    AppLogger.shared.log("[ChatVM] Ignoring message for unloaded task \(taskId.prefix(8))", level: .debug, category: "Chat")
                    return
                }
                var taskMsgs = self.messagesByTask[taskId] ?? []
                guard !taskMsgs.contains(where: { $0.messageId == message.messageId }) else { return }
                taskMsgs.append(message)
                taskMsgs.sort { $0.index < $1.index }
                self.messagesByTask[taskId] = taskMsgs
                self.rebuildDisplayItems()
                self.requestScrollToBottom()
            }
        }

        socketService.onMessagePatched { [weak self] message in
            guard let self, message.sessionId == self.currentSessionId else { return }
            if self.tasks.isEmpty {
                if let idx = self.virtualMessages.firstIndex(where: { $0.messageId == message.messageId }) {
                    self.virtualMessages[idx] = message
                    self.rebuildDisplayItems()
                }
            } else if let taskId = message.taskId, var taskMsgs = self.messagesByTask[taskId] {
                if let idx = taskMsgs.firstIndex(where: { $0.messageId == message.messageId }) {
                    taskMsgs[idx] = message
                    self.messagesByTask[taskId] = taskMsgs
                    self.rebuildDisplayItems()
                }
            }
        }

        socketService.onTaskCreated { [weak self] task in
            guard let self, task.sessionId == self.currentSessionId else { return }
            if !self.tasks.contains(where: { $0.taskId == task.taskId }) {
                // Collapse previously-last task, unload its messages
                if let previousLastId = self.tasks.last?.taskId {
                    self.collapsedTaskIds.insert(previousLastId)
                    self.unloadTaskMessages(previousLastId)
                }
                self.tasks.append(task)
                self.rebuildDisplayItems()
                // Load messages for the new task
                Task { await self.loadTaskMessages(task.taskId) }
            }
        }

        socketService.onTaskPatched { [weak self] task in
            guard let self, task.sessionId == self.currentSessionId else { return }
            if let idx = self.tasks.firstIndex(where: { $0.taskId == task.taskId }) {
                self.tasks[idx] = task
                self.rebuildDisplayItems()
                // When task fails, fetch its messages — executor may create a system error message
                // with the actual error text. Show error inline under the task header.
                if task.status == .failed {
                    Task {
                        await self.loadTaskMessages(task.taskId)
                        let msgs = self.messagesByTask[task.taskId] ?? []
                        if msgs.isEmpty {
                            self.taskErrors[task.taskId] = "Agent could not start — check server logs for details"
                            self.rebuildDisplayItems()
                        } else if let errorMsg = msgs.first(where: { $0.role == .system }),
                                  self.messagesByTask[task.taskId]?.count == 1 {
                            // Single system message = just the error, show it inline too
                            self.taskErrors[task.taskId] = errorMsg.contentPreview
                            self.rebuildDisplayItems()
                        }
                        AppLogger.shared.log("[Chat] task \(task.taskId.prefix(8)) failed (\(msgs.count) msgs)", level: .error, category: "Chat")
                    }
                }
            }
        }

        socketService.onSessionPatched { [weak self] session in
            guard let self else { return }
            self.handleVoiceSessionPatched(session)
            guard session.sessionId == self.currentSessionId else { return }
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
                AppLogger.shared.log("[Scroll] session needs attention — permId: \(permId?.prefix(8) ?? "nil"), inputId: \(inputId?.prefix(8) ?? "nil"), msgs: \(self.allMessages.count)", level: .debug, category: "Scroll")
                if let msgId = permId ?? inputId {
                    self.scrollToMessageInProgress = true
                    self.scrollToMessageId = "msg-\(msgId)"
                    AppLogger.shared.log("[Scroll] → scrollToMessageId = msg-\(msgId.prefix(8))", level: .debug, category: "Scroll")
                } else {
                    AppLogger.shared.log("[Scroll] ⚠️ no pending permission/input message found in \(self.allMessages.count) messages", level: .warning, category: "Scroll")
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
        for msg in allMessages.reversed() {
            if case .permissionRequest(let perm) = msg.content, perm.isPending {
                return msg.messageId
            }
        }
        return nil
    }

    var currentPendingInputId: String? {
        for msg in allMessages.reversed() {
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
        voiceSession = currentSession
        voiceLastAssistantMessage = allMessages.last(where: { $0.role == .assistant })
        voicePendingPromptText = nil
        UIApplication.shared.isIdleTimerDisabled = true

        let service = ContinuousVoiceService()
        service.vadConfig = vadConfig  // apply persisted settings before starting
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
                try await service.vad.initializeModel()
                try service.startListening()
                AppLogger.shared.log("[Voice] Voice mode enabled", level: .info, category: "Voice")
                // If agent is already working when voice is opened, announce it immediately
                await MainActor.run {
                    if let status = self.voiceSession?.status, status != .idle {
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
        voiceSession = nil
        voiceLastAssistantMessage = nil
        voicePendingPromptText = nil
        voiceStreamBuffer = ""
        voiceDidStreamCurrentMessage = false
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
        voiceDidStreamCurrentMessage = true
        voiceService?.speakStreamChunk(toSpeak)
    }

    private func handleVoiceInput(_ text: String) {
        guard let sessionId = voiceSessionId else { return }
        voicePendingPromptText = text
        if currentSessionId == sessionId {
            promptText = text
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(5000)) // Give user time to review
            guard self.voiceSessionId == sessionId else { return }

            if self.currentSessionId == sessionId {
                let currentDraft = self.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
                if currentDraft == text {
                    self.voicePendingPromptText = nil
                    self.promptText = ""
                    self.sendPrompt(to: sessionId, text: text, showSendingState: true)
                }
            } else if self.voicePendingPromptText == text {
                self.voicePendingPromptText = nil
                self.sendPrompt(to: sessionId, text: text, showSendingState: false)
            }
        }
    }

    private func updateVoiceListening() {
        guard let voice = voiceService else { return }

        if voiceSession?.status == .idle && voiceSession?.isPromptable == true {
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
        } else if voiceSession?.status != .idle {
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
        guard let lastMessage = voiceLastAssistantMessage,
              lastMessage.role == .assistant else {
            return false
        }

        // If we have a recent assistant message, consider it new
        return true
    }

    private func speakFinalMessage() {
        guard voiceModeEnabled, let lastMessage = voiceLastAssistantMessage else { return }

        // Already spoken (via onMessageCreated or streaming) — don't double-speak
        if lastMessage.messageId == lastSpokenMessageId {
            AppLogger.shared.log("[Voice] ⏭️ Final message already spoken — skipping", level: .info, category: "Voice")
            lastSpokenMessageId = nil
            return
        }

        // Stream chunks are still playing — let them finish; onMessageCreated will handle marking
        if voiceDidStreamCurrentMessage || voiceService?.isTTSSpeaking == true {
            AppLogger.shared.log("[Voice] ⏭️ Stream TTS in progress — letting chunks finish", level: .info, category: "Voice")
            lastSpokenMessageId = lastMessage.messageId
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

    private func handleVoiceMessageCreated(_ message: Message) {
        guard voiceModeEnabled,
              message.sessionId == voiceSessionId else { return }

        if message.role == .assistant {
            voiceLastAssistantMessage = message
        }

        guard message.role == .assistant else { return }

        if !voiceStreamBuffer.isEmpty {
            let remaining = voiceStreamBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            voiceStreamBuffer = ""
            voiceDidStreamCurrentMessage = false
            if !remaining.isEmpty {
                AppLogger.shared.log("[Voice] 💬 Flushing stream buffer (\(remaining.count) chars)", level: .info, category: "Voice")
                voiceService?.speakStreamChunk(remaining)
            }
            lastSpokenMessageId = message.messageId
        } else if voiceDidStreamCurrentMessage {
            AppLogger.shared.log("[Voice] ⏭️ Skipping onMessageCreated speak — already streamed", level: .info, category: "Voice")
            voiceDidStreamCurrentMessage = false
            lastSpokenMessageId = message.messageId
        } else {
            let text = extractTextFromMessage(message)
            if !text.isEmpty {
                let spokenText = text.count > 500 ? summarizeText(text) : text
                AppLogger.shared.log("[Voice] 💬 Speaking assistant message (\(text.count) chars)", level: .info, category: "Voice")
                voiceService?.speakMessage(spokenText)
                lastSpokenMessageId = message.messageId
            }
        }
    }

    private func handleVoiceSessionPatched(_ session: Session) {
        guard voiceModeEnabled,
              session.sessionId == voiceSessionId else { return }

        let oldStatus = voiceSession?.status
        voiceSession = session

        if oldStatus != session.status {
            handleVoiceStatusChange(from: oldStatus, to: session.status)
        }

        if session.status == .idle {
            streamingService.clearStreams(for: session.sessionId)
            activeStreams = streamingService.activeStreams
            rebuildDisplayItems()
        }

        updateVoiceListening()
    }

    var showsInlineVoiceControls: Bool {
        voiceModeEnabled && currentSessionId == voiceSessionId
    }

    private func draftText(for sessionId: String) -> String {
        if sessionId == voiceSessionId, let voicePendingPromptText {
            return voicePendingPromptText
        }
        return UserDefaults.standard.string(forKey: Self.draftKeyPrefix + sessionId) ?? ""
    }

}
