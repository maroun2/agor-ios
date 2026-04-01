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
    private var healthCheckTimer: Timer?

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
              let url = URL(string: client.baseURL) else {
            AppLogger.shared.log("Cannot connect: missing token or URL", level: .warning, category: "Socket")
            return
        }

        AppLogger.shared.log("Connecting to \(client.baseURL)", category: "Socket")
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
        AppLogger.shared.log("Disconnecting socket", level: .debug, category: "Socket")
        stopHealthCheck()
        socket?.disconnect()
        manager = nil
        socket = nil
        connectionState = .disconnected
    }

    func reconnect() {
        disconnect()
        connect()
    }

    // MARK: - Health Check

    func startHealthCheck(client: AgorClient) {
        stopHealthCheck()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task {
                let isHealthy = await client.healthCheck()
                await MainActor.run {
                    if !isHealthy && self.connectionState == .connected {
                        self.connectionState = .disconnected
                        self.reconnect()
                    } else if isHealthy && self.connectionState == .disconnected {
                        self.reconnect()
                    }
                }
            }
        }
    }

    func stopHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
    }

    // MARK: - Event Handlers

    private func setupEventHandlers() {
        guard let socket else { return }

        socket.on(clientEvent: .connect) { [weak self] _, _ in
            AppLogger.shared.log("Socket connected", category: "Socket")
            self?.connectionState = .connected
        }

        socket.on(clientEvent: .disconnect) { [weak self] _, _ in
            AppLogger.shared.log("Socket disconnected", category: "Socket")
            self?.connectionState = .disconnected
        }

        socket.on(clientEvent: .reconnect) { [weak self] _, _ in
            AppLogger.shared.log("Socket reconnecting", category: "Socket")
            self?.connectionState = .reconnecting
        }

        socket.on(clientEvent: .reconnectAttempt) { [weak self] _, _ in
            AppLogger.shared.log("Socket reconnect attempt", level: .debug, category: "Socket")
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

    // MARK: - FeathersJS Service Calls (via Socket.IO)

    /// Call a FeathersJS service `find` method via the authenticated socket connection.
    /// This mirrors how the web UI calls services — auth is resolved at socket level.
    func serviceFind<T: Decodable>(service: String, query: [String: Any]) async throws -> T {
        guard let socket, socket.status == .connected else {
            throw AgorAPIError.notAuthenticated
        }

        return try await withCheckedThrowingContinuation { continuation in
            socket.emitWithAck("find", service, ["query": query])
                .timingOut(after: 30) { data in
                    do {
                        let result = try self.parseFeathersAck(data)
                        let jsonData = try JSONSerialization.data(withJSONObject: result)
                        let decoded = try self.decoder.decode(T.self, from: jsonData)
                        continuation.resume(returning: decoded)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
        }
    }

    /// Call a FeathersJS service `get` method via the authenticated socket connection.
    func serviceGet<T: Decodable>(service: String, id: String, query: [String: Any] = [:]) async throws -> T {
        guard let socket, socket.status == .connected else {
            throw AgorAPIError.notAuthenticated
        }

        return try await withCheckedThrowingContinuation { continuation in
            socket.emitWithAck("get", service, id, ["query": query])
                .timingOut(after: 30) { data in
                    do {
                        let result = try self.parseFeathersAck(data)
                        let jsonData = try JSONSerialization.data(withJSONObject: result)
                        let decoded = try self.decoder.decode(T.self, from: jsonData)
                        continuation.resume(returning: decoded)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
        }
    }

    /// Parse FeathersJS socket ack response.
    /// FeathersJS ack format: success → [null, result], error → [errorObject]
    private func parseFeathersAck(_ data: [Any]) throws -> Any {
        // Timeout
        if let first = data.first as? String, first == "NO ACK" {
            throw AgorAPIError.networkError(URLError(.timedOut))
        }

        // Error: single element that's a dict with "code" key
        if data.count == 1, let errorDict = data[0] as? [String: Any], errorDict["code"] != nil {
            let code = errorDict["code"] as? Int ?? 500
            let message = errorDict["message"] as? String ?? "Unknown error"
            throw AgorAPIError.httpError(statusCode: code, body: message)
        }

        // Success: [null, result]
        if data.count >= 2 {
            if data[1] is NSNull {
                throw AgorAPIError.httpError(statusCode: 404, body: "Not found")
            }
            return data[1]
        }

        // Single result (no null prefix)
        if let first = data.first, !(first is NSNull) {
            return first
        }

        throw AgorAPIError.networkError(URLError(.cannotParseResponse))
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
