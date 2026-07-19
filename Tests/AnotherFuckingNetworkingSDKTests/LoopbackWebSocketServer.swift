import CryptoKit
import Foundation
import Network
@testable import AnotherFuckingNetworkingSDK

/// A one-client RFC 6455 server used only to exercise Foundation's real
/// WebSocket task and delegate path without depending on an external service.
final class LoopbackWebSocketServer: @unchecked Sendable {
    enum Behavior: Sendable {
        case accept(
            subprotocol: String? = nil,
            initialMessages: [WebSocketMessage] = []
        )
        case reject(statusCode: Int, headers: [String: String] = [:])
    }

    struct Snapshot: Sendable {
        let requestTarget: String?
        let requestHeaders: [String: String]
        let receivedMessages: [WebSocketMessage]
        let pingCount: Int
        let receivedClose: WebSocketClose?
        let failureDescription: String?
    }

    enum ServerError: LocalizedError, Sendable {
        case listenerStopped
        case listenerTimedOut
        case missingPort
        case connectionUnavailable
        case invalidHandshake(String)
        case oversizedHandshake
        case invalidFrame(String)
        case unsupportedStatusCode(Int)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .listenerStopped:
                return "The loopback listener stopped before becoming ready."
            case .listenerTimedOut:
                return "The loopback listener did not become ready within 5 seconds."
            case .missingPort:
                return "The loopback listener did not expose a local port."
            case .connectionUnavailable:
                return "The loopback WebSocket connection is unavailable."
            case .invalidHandshake(let detail):
                return "The loopback WebSocket handshake is invalid: \(detail)"
            case .oversizedHandshake:
                return "The loopback WebSocket handshake exceeded 32 KiB."
            case .invalidFrame(let detail):
                return "The loopback WebSocket frame is invalid: \(detail)"
            case .unsupportedStatusCode(let statusCode):
                return "The loopback HTTP status is unsupported: \(statusCode)."
            case .transport(let detail):
                return "The loopback transport failed: \(detail)"
            }
        }
    }

    private struct State {
        var startContinuation: CheckedContinuation<Void, any Error>?
        var port: UInt16?
        var connection: NWConnection?
        var requestTarget: String?
        var requestHeaders: [String: String] = [:]
        var receivedMessages: [WebSocketMessage] = []
        var pingCount = 0
        var receivedClose: WebSocketClose?
        var sentClose = false
        var isStopping = false
        var isComplete = false
        var failureDescription: String?
    }

    private struct HTTPRequestHead {
        let target: String
        let headers: [String: String]
    }

    private struct Frame {
        let opcode: UInt8
        let payload: Data
    }

    private let behavior: Behavior
    private let listener: NWListener
    private let queue = DispatchQueue(
        label: "AnotherFuckingNetworkingSDK.loopback-websocket.\(UUID())"
    )
    private let state = LockedBox(State())
    private let completionSignal = AsyncSignal()
    private let receivedMessageSignal = AsyncSignal()
    private let receivedPingSignal = AsyncSignal()

    private init(behavior: Behavior) throws {
        self.behavior = behavior
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: .any
        )
        parameters.acceptLocalOnly = true
        listener = try NWListener(using: parameters, on: .any)
    }

    deinit {
        stop()
    }

    static func start(behavior: Behavior) async throws -> Self {
        let server = try Self(behavior: behavior)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await server.start()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw ServerError.listenerTimedOut
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ServerError.listenerStopped
            }
            return result
        }
        return server
    }

    var baseURL: URL {
        get throws {
            guard let port = state.withLock({ $0.port }),
                  let url = URL(string: "http://127.0.0.1:\(port)") else {
                throw ServerError.missingPort
            }
            return url
        }
    }

    var snapshot: Snapshot {
        state.withLock { state in
            Snapshot(
                requestTarget: state.requestTarget,
                requestHeaders: state.requestHeaders,
                receivedMessages: state.receivedMessages,
                pingCount: state.pingCount,
                receivedClose: state.receivedClose,
                failureDescription: state.failureDescription
            )
        }
    }

    func waitForCompletion() async {
        await completionSignal.wait()
    }

    func waitForMessage() async {
        await receivedMessageSignal.wait()
    }

    func waitForPing() async {
        await receivedPingSignal.wait()
    }

    func send(_ message: WebSocketMessage) async throws {
        let frame: Data
        switch message {
        case .text(let text):
            frame = Self.makeFrame(opcode: 0x1, payload: Data(text.utf8))
        case .binary(let data):
            frame = Self.makeFrame(opcode: 0x2, payload: data)
        }
        try await send(frame)
    }

    func closePeer(
        code: WebSocketCloseCode,
        reason: String? = nil
    ) async throws {
        var payload = Data([
            UInt8((code.rawValue >> 8) & 0xff),
            UInt8(code.rawValue & 0xff),
        ])
        if let reason {
            payload.append(contentsOf: reason.utf8)
        }
        state.withLock { $0.sentClose = true }
        try await send(Self.makeFrame(opcode: 0x8, payload: payload))
    }

    func stop() {
        let connection = state.withLock { state -> NWConnection? in
            state.isStopping = true
            defer { state.connection = nil }
            return state.connection
        }
        connection?.cancel()
        listener.cancel()
        resolveStart(.failure(ServerError.listenerStopped))
    }

    private func start() async throws {
        listener.stateUpdateHandler = { [weak self] listenerState in
            self?.handle(listenerState)
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.startContinuation = continuation }
                listener.start(queue: queue)
            }
        } onCancel: {
            self.stop()
        }
    }

    private func handle(_ listenerState: NWListener.State) {
        switch listenerState {
        case .ready:
            guard let port = listener.port?.rawValue else {
                resolveStart(.failure(ServerError.missingPort))
                return
            }
            state.withLock { $0.port = port }
            resolveStart(.success(()))

        case .failed(let error):
            resolveStart(.failure(ServerError.transport(
                error.debugDescription
            )))

        case .cancelled:
            resolveStart(.failure(ServerError.listenerStopped))

        case .setup, .waiting:
            break

        @unknown default:
            break
        }
    }

    private func resolveStart(_ result: Result<Void, any Error>) {
        let continuation = state.withLock { state in
            defer { state.startContinuation = nil }
            return state.startContinuation
        }
        continuation?.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        let shouldAccept = state.withLock { state -> Bool in
            guard state.connection == nil, !state.isStopping else {
                return false
            }
            state.connection = connection
            return true
        }
        guard shouldAccept else {
            connection.cancel()
            return
        }

        connection.stateUpdateHandler = { [weak self, weak connection] status in
            guard let self, let connection else { return }
            if case .failed(let error) = status {
                let shouldIgnore = self.state.withLock {
                    $0.isComplete || $0.isStopping
                }
                guard !shouldIgnore else { return }
                self.fail(
                    ServerError.transport(error.debugDescription),
                    connection: connection
                )
            }
        }
        connection.start(queue: queue)
        receiveHandshake(on: connection, accumulated: Data())
    }

    private func receiveHandshake(
        on connection: NWConnection,
        accumulated: Data
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 8_192
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let error {
                self.fail(
                    ServerError.transport(error.debugDescription),
                    connection: connection
                )
                return
            }

            var bytes = accumulated
            if let data {
                bytes.append(data)
            }
            guard bytes.count <= 32 * 1_024 else {
                self.fail(ServerError.oversizedHandshake, connection: connection)
                return
            }

            let delimiter = Data("\r\n\r\n".utf8)
            if let range = bytes.range(of: delimiter) {
                let headerData = bytes[..<range.lowerBound]
                let remainder = Data(bytes[range.upperBound...])
                self.completeHandshake(
                    Data(headerData),
                    remainder: remainder,
                    on: connection
                )
            } else if isComplete {
                self.fail(
                    ServerError.invalidHandshake("connection ended early"),
                    connection: connection
                )
            } else {
                self.receiveHandshake(
                    on: connection,
                    accumulated: bytes
                )
            }
        }
    }

    private func completeHandshake(
        _ data: Data,
        remainder: Data,
        on connection: NWConnection
    ) {
        do {
            let request = try Self.parseRequestHead(data)
            state.withLock { state in
                state.requestTarget = request.target
                state.requestHeaders = request.headers
            }

            switch behavior {
            case .accept(let subprotocol, let initialMessages):
                let response = try Self.acceptanceResponse(
                    request: request,
                    subprotocol: subprotocol,
                    initialMessages: initialMessages
                )
                connection.send(content: response, completion: .contentProcessed {
                    [weak self, weak connection] error in
                    guard let self, let connection else { return }
                    if let error {
                        self.fail(
                            ServerError.transport(error.debugDescription),
                            connection: connection
                        )
                    } else {
                        self.receiveFrames(
                            on: connection,
                            accumulated: remainder
                        )
                    }
                })

            case .reject(let statusCode, let headers):
                let response = try Self.rejectionResponse(
                    statusCode: statusCode,
                    headers: headers
                )
                connection.send(
                    content: response,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed {
                        [weak self, weak connection] error in
                        guard let self, let connection else { return }
                        if let error {
                            self.fail(
                                ServerError.transport(error.debugDescription),
                                connection: connection
                            )
                        } else {
                            self.complete(
                                connection: connection,
                                cancelConnection: false
                            )
                        }
                    }
                )
            }
        } catch {
            fail(error, connection: connection)
        }
    }

    private func receiveFrames(
        on connection: NWConnection,
        accumulated: Data
    ) {
        do {
            var remainder = accumulated
            while let parsed = try Self.parseFrame(remainder) {
                remainder.removeFirst(parsed.consumedByteCount)
                guard process(parsed.frame, on: connection) else { return }
            }
            let pendingBytes = remainder

            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 64 * 1_024
            ) { [weak self, weak connection] data, _, isComplete, error in
                guard let self, let connection else { return }
                if let error {
                    let isStopping = self.state.withLock { $0.isStopping }
                    if isStopping {
                        self.complete(connection: connection)
                    } else {
                        self.fail(
                            ServerError.transport(error.debugDescription),
                            connection: connection
                        )
                    }
                    return
                }

                var next = pendingBytes
                if let data {
                    next.append(data)
                }
                if isComplete {
                    if next.isEmpty {
                        self.complete(connection: connection)
                    } else {
                        self.fail(
                            ServerError.invalidFrame(
                                "connection ended with an incomplete frame"
                            ),
                            connection: connection
                        )
                    }
                } else {
                    self.receiveFrames(on: connection, accumulated: next)
                }
            }
        } catch {
            fail(error, connection: connection)
        }
    }

    private func process(_ frame: Frame, on connection: NWConnection) -> Bool {
        switch frame.opcode {
        case 0x1:
            guard let text = String(data: frame.payload, encoding: .utf8) else {
                fail(
                    ServerError.invalidFrame("text payload is not UTF-8"),
                    connection: connection
                )
                return false
            }
            state.withLock { $0.receivedMessages.append(.text(text)) }
            Task { await receivedMessageSignal.signal() }

        case 0x2:
            state.withLock { $0.receivedMessages.append(.binary(frame.payload)) }
            Task { await receivedMessageSignal.signal() }

        case 0x8:
            do {
                let close = try Self.parseClose(frame.payload)
                let shouldEcho = state.withLock { state -> Bool in
                    state.receivedClose = close
                    guard !state.sentClose else { return false }
                    state.sentClose = true
                    return true
                }
                if shouldEcho {
                    let response = Self.makeFrame(
                        opcode: 0x8,
                        payload: frame.payload
                    )
                    connection.send(
                        content: response,
                        contentContext: .finalMessage,
                        isComplete: true,
                        completion: .contentProcessed {
                            [weak self, weak connection] error in
                            guard let self, let connection else { return }
                            if let error {
                                self.fail(
                                    ServerError.transport(error.debugDescription),
                                    connection: connection
                                )
                            } else {
                                self.complete(
                                    connection: connection,
                                    cancelConnection: false
                                )
                            }
                        }
                    )
                } else {
                    complete(connection: connection)
                }
                return false
            } catch {
                fail(error, connection: connection)
                return false
            }

        case 0x9:
            state.withLock { $0.pingCount += 1 }
            Task { await receivedPingSignal.signal() }
            let pong = Self.makeFrame(opcode: 0xA, payload: frame.payload)
            connection.send(content: pong, completion: .contentProcessed {
                [weak self, weak connection] error in
                guard let self, let connection, let error else { return }
                self.fail(
                    ServerError.transport(error.debugDescription),
                    connection: connection
                )
            })

        case 0xA:
            break

        default:
            fail(
                ServerError.invalidFrame(
                    "unsupported opcode \(frame.opcode)"
                ),
                connection: connection
            )
            return false
        }
        return true
    }

    private func send(_ data: Data) async throws {
        guard let connection = state.withLock({ $0.connection }) else {
            throw ServerError.connectionUnavailable
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed {
                error in
                if let error {
                    continuation.resume(throwing: ServerError.transport(
                        error.debugDescription
                    ))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func fail(_ error: any Error, connection: NWConnection) {
        state.withLock { state in
            if state.failureDescription == nil {
                state.failureDescription = error.localizedDescription
            }
        }
        complete(connection: connection)
    }

    private func complete(
        connection: NWConnection,
        cancelConnection: Bool = true
    ) {
        let shouldSignal = state.withLock { state -> Bool in
            guard !state.isComplete else { return false }
            state.isComplete = true
            if cancelConnection {
                state.connection = nil
            }
            return true
        }
        guard shouldSignal else { return }
        if cancelConnection {
            connection.cancel()
        }
        listener.cancel()
        Task { await completionSignal.signal() }
    }

    private static func parseRequestHead(_ data: Data) throws -> HTTPRequestHead {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ServerError.invalidHandshake("headers are not UTF-8")
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw ServerError.invalidHandshake("missing request line")
        }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count == 3,
              requestParts[0] == "GET",
              requestParts[2].hasPrefix("HTTP/1.") else {
            throw ServerError.invalidHandshake("invalid request line")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                throw ServerError.invalidHandshake("malformed header")
            }
            let name = line[..<separator]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return HTTPRequestHead(
            target: String(requestParts[1]),
            headers: headers
        )
    }

    private static func acceptanceResponse(
        request: HTTPRequestHead,
        subprotocol: String?,
        initialMessages: [WebSocketMessage]
    ) throws -> Data {
        guard request.headers["upgrade"]?.lowercased() == "websocket",
              request.headers["connection"]?.lowercased().contains("upgrade")
                == true,
              request.headers["sec-websocket-version"] == "13",
              let key = request.headers["sec-websocket-key"] else {
            throw ServerError.invalidHandshake("missing upgrade headers")
        }

        if let subprotocol {
            let offered = request.headers["sec-websocket-protocol"]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            guard offered.contains(subprotocol) else {
                throw ServerError.invalidHandshake(
                    "selected subprotocol was not offered"
                )
            }
        }

        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        let accept = Data(digest).base64EncodedString()
        var lines = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
        ]
        if let subprotocol {
            lines.append("Sec-WebSocket-Protocol: \(subprotocol)")
        }

        var response = Data((lines.joined(separator: "\r\n")
            + "\r\n\r\n").utf8)
        for message in initialMessages {
            switch message {
            case .text(let text):
                response.append(makeFrame(
                    opcode: 0x1,
                    payload: Data(text.utf8)
                ))
            case .binary(let data):
                response.append(makeFrame(opcode: 0x2, payload: data))
            }
        }
        return response
    }

    private static func rejectionResponse(
        statusCode: Int,
        headers: [String: String]
    ) throws -> Data {
        let reason: String
        switch statusCode {
        case 400:
            reason = "Bad Request"
        case 401:
            reason = "Unauthorized"
        case 403:
            reason = "Forbidden"
        case 404:
            reason = "Not Found"
        case 500:
            reason = "Internal Server Error"
        default:
            throw ServerError.unsupportedStatusCode(statusCode)
        }
        var lines = [
            "HTTP/1.1 \(statusCode) \(reason)",
            "Content-Length: 0",
            "Connection: close",
        ]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }
        return Data((lines.joined(separator: "\r\n")
            + "\r\n\r\n").utf8)
    }

    private static func makeFrame(opcode: UInt8, payload: Data) -> Data {
        var bytes = Data([0x80 | opcode])
        switch payload.count {
        case 0...125:
            bytes.append(UInt8(payload.count))
        case 126...65_535:
            bytes.append(126)
            bytes.append(UInt8((payload.count >> 8) & 0xff))
            bytes.append(UInt8(payload.count & 0xff))
        default:
            bytes.append(127)
            let count = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8((count >> UInt64(shift)) & 0xff))
            }
        }
        bytes.append(payload)
        return bytes
    }

    private static func parseFrame(
        _ data: Data
    ) throws -> (frame: Frame, consumedByteCount: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        guard bytes[0] & 0x80 != 0 else {
            throw ServerError.invalidFrame("fragmented frames are unsupported")
        }
        guard bytes[1] & 0x80 != 0 else {
            throw ServerError.invalidFrame("client frame is not masked")
        }

        var cursor = 2
        var payloadLength = UInt64(bytes[1] & 0x7f)
        if payloadLength == 126 {
            guard bytes.count >= cursor + 2 else { return nil }
            payloadLength = (UInt64(bytes[cursor]) << 8)
                | UInt64(bytes[cursor + 1])
            cursor += 2
        } else if payloadLength == 127 {
            guard bytes.count >= cursor + 8 else { return nil }
            payloadLength = 0
            for byte in bytes[cursor..<(cursor + 8)] {
                payloadLength = (payloadLength << 8) | UInt64(byte)
            }
            cursor += 8
        }

        guard payloadLength <= 16 * 1_024 * 1_024 else {
            throw ServerError.invalidFrame("payload exceeds 16 MiB")
        }
        guard bytes.count >= cursor + 4 else { return nil }
        let mask = Array(bytes[cursor..<(cursor + 4)])
        cursor += 4
        guard payloadLength <= UInt64(Int.max) else {
            throw ServerError.invalidFrame("payload length overflows Int")
        }
        let count = Int(payloadLength)
        guard bytes.count >= cursor + count else { return nil }

        var payload = Array(bytes[cursor..<(cursor + count)])
        for index in payload.indices {
            payload[index] ^= mask[index % 4]
        }
        return (
            Frame(opcode: bytes[0] & 0x0f, payload: Data(payload)),
            cursor + count
        )
    }

    private static func parseClose(_ payload: Data) throws -> WebSocketClose? {
        guard !payload.isEmpty else { return nil }
        let bytes = [UInt8](payload)
        guard bytes.count >= 2 else {
            throw ServerError.invalidFrame("close payload is one byte")
        }
        let code = (Int(bytes[0]) << 8) | Int(bytes[1])
        let reason = bytes.count > 2 ? Data(bytes.dropFirst(2)) : nil
        if let reason, String(data: reason, encoding: .utf8) == nil {
            throw ServerError.invalidFrame("close reason is not UTF-8")
        }
        return WebSocketClose(
            code: WebSocketCloseCode(rawValue: code),
            reason: reason
        )
    }
}
