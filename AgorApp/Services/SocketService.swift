import Foundation
import SocketIO

// MARK: - Connection State

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

// MARK: - Socket Service

@Observable
final class SocketService {
    var connectionState: ConnectionState = .disconnected

    // Multi-subscriber event callbacks
    private var sessionPatchedHandlers: [(Session) -> Void] = []
    private var taskCreatedHandlers: [(AgorTask) -> Void] = []
    private var taskPatchedHandlers: [(AgorTask) -> Void] = []
    private var messageCreatedHandlers: [(Message) -> Void] = []
    private var messagePatchedHandlers: [(Message) -> Void] = []

    // Streaming callbacks (single subscriber is fine — only ChatVM uses these)
    var onStreamingStart: ((StreamingStartEvent) -> Void)?
    var onStreamingChunk: ((StreamingChunkEvent) -> Void)?
    var onStreamingEnd: ((StreamingEndEvent) -> Void)?
    var onStreamingError: ((StreamingErrorEvent) -> Void)?
    var onThinkingStart: ((ThinkingStartEvent) -> Void)?
    var onThinkingChunk: ((ThinkingChunkEvent) -> Void)?
    var onThinkingEnd: ((ThinkingEndEvent) -> Void)?

    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private let client: AgorClient
    private let decoder = JSONDecoder.agor

    init(client: AgorClient) {
        self.client = client
    }

    // MARK: - Subscribe (multi-handler)

    func onSessionPatched(_ handler: @escaping (Session) -> Void) {
        sessionPatchedHandlers.append(handler)
    }

    func onTaskCreated(_ handler: @escaping (AgorTask) -> Void) {
        taskCreatedHandlers.append(handler)
    }

    func onTaskPatched(_ handler: @escaping (AgorTask) -> Void) {
        taskPatchedHandlers.append(handler)
    }

    func onMessageCreated(_ handler: @escaping (Message) -> Void) {
        messageCreatedHandlers.append(handler)
    }

    func onMessagePatched(_ handler: @escaping (Message) -> Void) {
        messagePatchedHandlers.append(handler)
    }

    // MARK: - Connection

    func connect() {
        guard let token = client.accessToken,
              let url = URL(string: client.baseURL) else { return }

        connectionState = .connecting

        manager = SocketManager(socketURL: url, config: [
            .extraHeaders(["Authorization": "Bearer \(token)"]),
            .forceWebsockets(true),
            .reconnects(true),
            .reconnectWait(2),
            .reconnectWaitMax(30),
            .log(false),
        ])

        socket = manager?.defaultSocket
        setupEventHandlers()
        socket?.connect()
    }

    func disconnect() {
        socket?.disconnect()
        manager = nil
        socket = nil
        connectionState = .disconnected
    }

    func reconnect() {
        disconnect()
        connect()
    }

    // MARK: - Event Handlers

    private func setupEventHandlers() {
        guard let socket else { return }

        socket.on(clientEvent: .connect) { [weak self] _, _ in
            self?.connectionState = .connected
        }

        socket.on(clientEvent: .disconnect) { [weak self] _, _ in
            self?.connectionState = .disconnected
        }

        socket.on(clientEvent: .reconnect) { [weak self] _, _ in
            self?.connectionState = .reconnecting
        }

        socket.on(clientEvent: .reconnectAttempt) { [weak self] _, _ in
            self?.connectionState = .reconnecting
        }

        // FeathersJS CRUD events: "<service> <action>"
        socket.on("sessions patched") { [weak self] data, _ in
            self?.handleDecodable(data) { (session: Session) in
                self?.sessionPatchedHandlers.forEach { $0(session) }
            }
        }

        socket.on("tasks created") { [weak self] data, _ in
            self?.handleDecodable(data) { (task: AgorTask) in
                self?.taskCreatedHandlers.forEach { $0(task) }
            }
        }

        socket.on("tasks patched") { [weak self] data, _ in
            self?.handleDecodable(data) { (task: AgorTask) in
                self?.taskPatchedHandlers.forEach { $0(task) }
            }
        }

        socket.on("messages created") { [weak self] data, _ in
            self?.handleDecodable(data) { (message: Message) in
                self?.messageCreatedHandlers.forEach { $0(message) }
            }
        }

        socket.on("messages patched") { [weak self] data, _ in
            self?.handleDecodable(data) { (message: Message) in
                self?.messagePatchedHandlers.forEach { $0(message) }
            }
        }

        // Streaming events
        socket.on("messages streaming:start") { [weak self] data, _ in
            self?.handleDecodable(data) { (event: StreamingStartEvent) in
                self?.onStreamingStart?(event)
            }
        }

        socket.on("messages streaming:chunk") { [weak self] data, _ in
            self?.handleDecodable(data) { (event: StreamingChunkEvent) in
                self?.onStreamingChunk?(event)
            }
        }

        socket.on("messages streaming:end") { [weak self] data, _ in
            self?.handleDecodable(data) { (event: StreamingEndEvent) in
                self?.onStreamingEnd?(event)
            }
        }

        socket.on("messages streaming:error") { [weak self] data, _ in
            self?.handleDecodable(data) { (event: StreamingErrorEvent) in
                self?.onStreamingError?(event)
            }
        }

        socket.on("messages thinking:start") { [weak self] data, _ in
            self?.handleDecodable(data) { (event: ThinkingStartEvent) in
                self?.onThinkingStart?(event)
            }
        }

        socket.on("messages thinking:chunk") { [weak self] data, _ in
            self?.handleDecodable(data) { (event: ThinkingChunkEvent) in
                self?.onThinkingChunk?(event)
            }
        }

        socket.on("messages thinking:end") { [weak self] data, _ in
            self?.handleDecodable(data) { (event: ThinkingEndEvent) in
                self?.onThinkingEnd?(event)
            }
        }
    }

    // MARK: - Decoding Helpers

    private func handleDecodable<T: Decodable>(_ data: [Any], handler: @escaping (T) -> Void) {
        guard let first = data.first else { return }

        do {
            let jsonData: Data
            if let dict = first as? [String: Any] {
                jsonData = try JSONSerialization.data(withJSONObject: dict)
            } else if let d = first as? Data {
                jsonData = d
            } else {
                return
            }
            let decoded = try decoder.decode(T.self, from: jsonData)
            DispatchQueue.main.async {
                handler(decoded)
            }
        } catch {
            #if DEBUG
            print("[SocketService] Decode error for \(T.self): \(error)")
            #endif
        }
    }
}
