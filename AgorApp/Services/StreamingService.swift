import Foundation

// MARK: - Streaming Service

@Observable
final class StreamingService {
    var activeStreams: [String: StreamingMessage] = [:]

    // Debounce timer for UI updates
    private var debounceTask: Task<Void, Never>?
    private var pendingUpdates: [String: StreamingMessage] = [:]
    private let debounceInterval: Duration = .milliseconds(50)

    var onStreamsChanged: (() -> Void)?

    // MARK: - Event Handlers

    func handleStreamingStart(_ event: StreamingStartEvent) {
        let message = StreamingMessage(
            messageId: event.messageId,
            sessionId: event.sessionId,
            taskId: event.taskId,
            timestamp: event.timestamp ?? ISO8601DateFormatter().string(from: Date()),
            isStreaming: true
        )
        activeStreams[event.messageId] = message
        notifyChange()
    }

    func handleStreamingChunk(_ event: StreamingChunkEvent) {
        if var stream = activeStreams[event.messageId] {
            stream.content += event.chunk
            activeStreams[event.messageId] = stream
            debouncedNotify()
        }
    }

    func handleStreamingEnd(_ event: StreamingEndEvent) {
        if var stream = activeStreams[event.messageId] {
            stream.isStreaming = false
            activeStreams[event.messageId] = stream
            notifyChange()
        }
    }

    func handleStreamingError(_ event: StreamingErrorEvent) {
        if var stream = activeStreams[event.messageId] {
            stream.isStreaming = false
            stream.hasError = true
            stream.errorMessage = event.error
            activeStreams[event.messageId] = stream
            notifyChange()
        }
    }

    func handleThinkingStart(_ event: ThinkingStartEvent) {
        if var stream = activeStreams[event.messageId] {
            stream.isThinking = true
            stream.thinkingContent = ""
            activeStreams[event.messageId] = stream
            notifyChange()
        } else {
            // Thinking may start before streaming:start
            var message = StreamingMessage(
                messageId: event.messageId,
                sessionId: event.sessionId,
                taskId: event.taskId,
                timestamp: event.timestamp ?? ISO8601DateFormatter().string(from: Date()),
                isStreaming: true,
                isThinking: true
            )
            message.thinkingContent = ""
            activeStreams[event.messageId] = message
            notifyChange()
        }
    }

    func handleThinkingChunk(_ event: ThinkingChunkEvent) {
        if var stream = activeStreams[event.messageId] {
            stream.thinkingContent = (stream.thinkingContent ?? "") + event.chunk
            activeStreams[event.messageId] = stream
            debouncedNotify()
        }
    }

    func handleThinkingEnd(_ event: ThinkingEndEvent) {
        if var stream = activeStreams[event.messageId] {
            stream.isThinking = false
            activeStreams[event.messageId] = stream
            notifyChange()
        }
    }

    // MARK: - Message Created (handoff from streaming to persisted)

    func handleMessageCreated(messageId: String) {
        activeStreams.removeValue(forKey: messageId)
        notifyChange()
    }

    // MARK: - Session Change

    func getStreams(for sessionId: String) -> [StreamingMessage] {
        activeStreams.values.filter { $0.sessionId == sessionId }
            .sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Debounced Notification

    private func notifyChange() {
        debounceTask?.cancel()
        onStreamsChanged?()
    }

    private func debouncedNotify() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            onStreamsChanged?()
        }
    }
}
