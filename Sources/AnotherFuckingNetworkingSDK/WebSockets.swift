import Foundation

// MARK: - Public request and message types

/// A type-safe description of a WebSocket handshake.
public protocol WebSocketRequest: Sendable {
    /// The endpoint path relative to the client's base URL.
    var path: String { get }

    /// How ``path`` should be interpreted.
    var pathEncoding: RequestPathEncoding { get }

    /// Query items appended after any query items in the base URL.
    var queryItems: [URLQueryItem]? { get }

    /// Handshake headers. They override matching client headers
    /// case-insensitively.
    var headers: [String: String]? { get }

    /// Ordered application subprotocols advertised during the handshake.
    var subprotocols: [String] { get }

    /// An optional maximum number of bytes Foundation may buffer for one
    /// received message. `nil` preserves Foundation's default.
    var maximumMessageSize: Int? { get }

    /// Builds the endpoint URL before its scheme is converted to `ws` or `wss`.
    func makeURL(baseURL: URL) -> URL?

    /// Applies final request-specific handshake options.
    func customize(_ urlRequest: inout URLRequest) throws
}

public extension WebSocketRequest {
    var pathEncoding: RequestPathEncoding { .decoded }
    var queryItems: [URLQueryItem]? { nil }
    var headers: [String: String]? { nil }
    var subprotocols: [String] { [] }
    var maximumMessageSize: Int? { nil }

    func makeURL(baseURL: URL) -> URL? {
        DefaultWebSocketURLTarget(
            path: path,
            pathEncoding: pathEncoding,
            queryItems: queryItems
        ).makeURL(baseURL: baseURL)
    }

    func customize(_ urlRequest: inout URLRequest) throws {}
}

private struct DefaultWebSocketURLTarget: HTTPRequest {
    let path: String
    let pathEncoding: RequestPathEncoding
    let queryItems: [URLQueryItem]?
}

/// A complete text or binary WebSocket message.
public enum WebSocketMessage: Equatable, Sendable {
    /// A complete UTF-8 text message.
    case text(String)

    /// A complete binary message.
    case binary(Data)
}

/// A WebSocket close code, including application-defined values.
public struct WebSocketCloseCode: RawRepresentable, Equatable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let normalClosure = Self(rawValue: 1_000)
    public static let goingAway = Self(rawValue: 1_001)
    public static let protocolError = Self(rawValue: 1_002)
    public static let unsupportedData = Self(rawValue: 1_003)
    public static let invalidFramePayloadData = Self(rawValue: 1_007)
    public static let policyViolation = Self(rawValue: 1_008)
    public static let messageTooBig = Self(rawValue: 1_009)
    public static let mandatoryExtensionMissing = Self(rawValue: 1_010)
    public static let internalServerError = Self(rawValue: 1_011)
    public static let serviceRestart = Self(rawValue: 1_012)
    public static let tryAgainLater = Self(rawValue: 1_013)
    public static let badGateway = Self(rawValue: 1_014)

    fileprivate var isValidForSending: Bool {
        let isStandard = (1_000...1_014).contains(rawValue)
            && ![1_004, 1_005, 1_006].contains(rawValue)
        return isStandard || (3_000...4_999).contains(rawValue)
    }

    fileprivate var endsMessageSequence: Bool {
        self == .normalClosure || self == .goingAway
    }
}

/// Close details received from a WebSocket peer.
public struct WebSocketClose: Equatable, Sendable {
    public let code: WebSocketCloseCode
    public let reason: Data?

    public init(code: WebSocketCloseCode, reason: Data? = nil) {
        self.code = code
        self.reason = reason
    }

    public var reasonText: String? {
        reason.flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// The observable lifecycle of a connected WebSocket.
public enum WebSocketConnectionState: Equatable, Sendable {
    /// The upgrade handshake succeeded and messages may be exchanged.
    case open

    /// A local closing handshake has started.
    case closing

    /// The task completed, optionally with peer-provided close details.
    case closed(WebSocketClose?)
}

/// An error produced while constructing or operating a WebSocket.
public enum WebSocketError: LocalizedError, Sendable {
    case invalidURL
    case invalidMaximumMessageSize(Int)
    case invalidSubprotocol(String)
    case duplicateSubprotocol(String)
    case reservedHeader(String)
    case conflictingSubprotocolHeader
    case invalidHandshakeMethod
    case handshakeBodyNotAllowed
    case handshakeFailed(
        metadata: HTTPResponseMetadata,
        underlying: (any Error)?
    )
    case requestConfigurationFailed(any Error)
    case connectionAlreadyStarted
    case connectionClosing
    case connectionClosed(WebSocketClose?)
    case concurrentReceive
    case invalidCloseCode(Int)
    case closeReasonTooLong(maximumBytes: Int, actualBytes: Int)
    case unsupportedMessage
    case transport(URLError)
    case unknown(any Error)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The WebSocket URL is invalid."
        case .invalidMaximumMessageSize(let value):
            return "The maximum WebSocket message size must be positive, not \(value)."
        case .invalidSubprotocol(let value):
            return "The WebSocket subprotocol is invalid: \(value)."
        case .duplicateSubprotocol(let value):
            return "The WebSocket subprotocol is duplicated: \(value)."
        case .reservedHeader(let name):
            return "Foundation owns the reserved WebSocket header: \(name)."
        case .conflictingSubprotocolHeader:
            return "Configure WebSocket subprotocols with the subprotocols property."
        case .invalidHandshakeMethod:
            return "A WebSocket handshake must use GET."
        case .handshakeBodyNotAllowed:
            return "A WebSocket handshake cannot contain a request body."
        case .handshakeFailed(let metadata, _):
            return "The WebSocket upgrade failed with HTTP \(metadata.statusCode)."
        case .requestConfigurationFailed(let error):
            return "The WebSocket handshake could not be configured: \(error.localizedDescription)"
        case .connectionAlreadyStarted:
            return "The WebSocket connection has already been started."
        case .connectionClosing:
            return "The WebSocket connection is closing."
        case .connectionClosed(let close):
            if let close {
                return "The WebSocket connection closed with code \(close.code.rawValue)."
            }
            return "The WebSocket connection is closed."
        case .concurrentReceive:
            return "Only one WebSocket receive operation may be active at a time."
        case .invalidCloseCode(let value):
            return "The WebSocket close code cannot be sent: \(value)."
        case .closeReasonTooLong(let maximumBytes, let actualBytes):
            return "The WebSocket close reason is \(actualBytes) bytes; the maximum is \(maximumBytes)."
        case .unsupportedMessage:
            return "Foundation returned an unsupported WebSocket message type."
        case .transport(let error):
            return "The WebSocket transport failed: \(error.localizedDescription)"
        case .unknown(let error):
            return "The WebSocket failed unexpectedly: \(error.localizedDescription)"
        }
    }
}

// MARK: - Public client and connection protocols

/// A client that opens authenticated, configuration-aware WebSocket handshakes.
public protocol WebSocketClientProtocol: Sendable {
    /// Waits for the HTTP upgrade handshake and returns an open connection.
    func connect<R: WebSocketRequest>(
        _ request: R
    ) async throws -> any WebSocketConnectionProtocol
}

/// A connected, concurrency-safe WebSocket.
public protocol WebSocketConnectionProtocol: Sendable {
    var url: URL { get }
    var negotiatedSubprotocol: String? { get }
    var state: WebSocketConnectionState { get async }

    /// Sends one complete message.
    ///
    /// Success means Foundation accepted the message for transmission; it is
    /// not an acknowledgement from the peer.
    func send(_ message: WebSocketMessage) async throws

    /// Receives one complete message. Only one receive may be active at once.
    func receive() async throws -> WebSocketMessage

    /// Sends a ping and waits for Foundation's pong callback.
    func ping() async throws

    /// Starts a closing handshake without waiting for the peer to complete it.
    func close(code: WebSocketCloseCode, reason: String?) async throws
}

public extension WebSocketConnectionProtocol {
    var messages: WebSocketMessages {
        WebSocketMessages(connection: self)
    }

    func send(text: String) async throws {
        try await send(.text(text))
    }

    func send(data: Data) async throws {
        try await send(.binary(data))
    }

    func close() async throws {
        try await close(code: .normalClosure, reason: nil)
    }
}

/// A demand-driven asynchronous sequence that performs one receive per call to
/// its iterator's `next()` method. Normal and going-away close frames end the
/// sequence; abnormal termination is thrown.
public struct WebSocketMessages: AsyncSequence, Sendable {
    public typealias Element = WebSocketMessage

    private let connection: any WebSocketConnectionProtocol

    fileprivate init(connection: any WebSocketConnectionProtocol) {
        self.connection = connection
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(connection: connection)
    }

    public struct Iterator: AsyncIteratorProtocol, Sendable {
        private let connection: any WebSocketConnectionProtocol

        fileprivate init(connection: any WebSocketConnectionProtocol) {
            self.connection = connection
        }

        public mutating func next() async throws -> WebSocketMessage? {
            do {
                return try await connection.receive()
            } catch WebSocketError.connectionClosed(let close)
                where close?.code.endsMessageSequence == true {
                return nil
            }
        }
    }
}

// MARK: - Request construction

package enum WebSocketRequestBuilder {
    private static let reservedHeaders: Set<String> = [
        "connection",
        "host",
        "upgrade",
        "sec-websocket-accept",
        "sec-websocket-extensions",
        "sec-websocket-key",
        "sec-websocket-version"
    ]

    package static func make<R: WebSocketRequest>(
        _ request: R,
        baseURL: URL?,
        globalHeaders: [String: String]
    ) throws -> URLRequest {
        guard let baseURL,
              let unresolvedURL = request.makeURL(baseURL: baseURL),
              let webSocketURL = webSocketURL(from: unresolvedURL) else {
            throw WebSocketError.invalidURL
        }

        if let maximumMessageSize = request.maximumMessageSize,
           maximumMessageSize <= 0 {
            throw WebSocketError.invalidMaximumMessageSize(maximumMessageSize)
        }

        try validate(subprotocols: request.subprotocols)

        var headers = normalizedHeaders(globalHeaders)
        for (name, value) in normalizedHeaders(request.headers ?? [:]) {
            headers[name] = value
        }
        try validateCallerHeaders(headers)

        var urlRequest = URLRequest(url: webSocketURL)
        urlRequest.httpMethod = HTTPMethod.get.rawValue
        for (name, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let expectedSubprotocolHeader: String?
        if request.subprotocols.isEmpty {
            expectedSubprotocolHeader = nil
        } else {
            let header = request.subprotocols.joined(separator: ", ")
            urlRequest.setValue(header, forHTTPHeaderField: "Sec-WebSocket-Protocol")
            expectedSubprotocolHeader = header
        }

        do {
            try request.customize(&urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WebSocketError.requestConfigurationFailed(error)
        }

        try validateFinalRequest(
            urlRequest,
            expectedSubprotocolHeader: expectedSubprotocolHeader
        )
        return urlRequest
    }

    private static func webSocketURL(from url: URL) -> URL? {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ), components.fragment == nil else {
            return nil
        }

        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        case "wss", "ws":
            break
        default:
            return nil
        }
        guard let host = components.host, !host.isEmpty else { return nil }
        return components.url
    }

    private static func validate(subprotocols: [String]) throws {
        var seen: Set<String> = []
        for value in subprotocols {
            guard !value.isEmpty,
                  value.unicodeScalars.allSatisfy({ $0.isWebSocketToken }) else {
                throw WebSocketError.invalidSubprotocol(value)
            }
            guard seen.insert(value).inserted else {
                throw WebSocketError.duplicateSubprotocol(value)
            }
        }
    }

    private static func validateCallerHeaders(
        _ headers: [String: String]
    ) throws {
        for name in headers.keys {
            if reservedHeaders.contains(name) {
                throw WebSocketError.reservedHeader(name)
            }
            if name == "sec-websocket-protocol" {
                throw WebSocketError.conflictingSubprotocolHeader
            }
        }
    }

    private static func validateFinalRequest(
        _ request: URLRequest,
        expectedSubprotocolHeader: String?
    ) throws {
        guard let url = request.url,
              webSocketURL(from: url) == url else {
            throw WebSocketError.invalidURL
        }
        guard request.httpMethod == HTTPMethod.get.rawValue else {
            throw WebSocketError.invalidHandshakeMethod
        }
        guard request.httpBody == nil, request.httpBodyStream == nil else {
            throw WebSocketError.handshakeBodyNotAllowed
        }

        let headers = normalizedHeaders(request.allHTTPHeaderFields ?? [:])
        for name in reservedHeaders where headers[name] != nil {
            throw WebSocketError.reservedHeader(name)
        }
        guard headers["sec-websocket-protocol"] == expectedSubprotocolHeader else {
            throw WebSocketError.conflictingSubprotocolHeader
        }
    }

    private static func normalizedHeaders(
        _ headers: [String: String]
    ) -> [String: String] {
        var normalized: [String: String] = [:]
        for name in headers.keys.sorted() {
            normalized[name.lowercased()] = headers[name]
        }
        return normalized
    }
}

private extension Unicode.Scalar {
    var isWebSocketToken: Bool {
        switch value {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return "!#$%&'*+-.^_`|~".unicodeScalars.contains(self)
        }
    }
}

// MARK: - Internal task adapter

enum WebSocketTaskEvent: Sendable {
    case opened(negotiatedSubprotocol: String?)
    case closed(WebSocketClose)
    case completed((any Error)?)
}

protocol WebSocketTaskAdapter: Sendable {
    func setEventHandler(
        _ handler: @escaping @Sendable (WebSocketTaskEvent) -> Void
    )
    func resume()
    func send(
        _ message: WebSocketMessage,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    )
    func receive(
        completion: @escaping @Sendable (
            Result<WebSocketMessage, any Error>
        ) -> Void
    )
    func ping(
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    )
    func close(code: WebSocketCloseCode, reason: Data?)
    func cancel()
    func closeDetails() -> WebSocketClose?
    func handshakeResponse() -> HTTPURLResponse?
}

extension WebSocketTaskAdapter {
    func closeDetails() -> WebSocketClose? { nil }
    func handshakeResponse() -> HTTPURLResponse? { nil }
}

private final class FoundationWebSocketTaskAdapter: WebSocketTaskAdapter,
    @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let lifecycleDelegate: FoundationWebSocketLifecycleDelegate

    init(
        session: URLSession,
        request: URLRequest,
        maximumMessageSize: Int?
    ) {
        let task = session.webSocketTask(with: request)
        if let maximumMessageSize {
            task.maximumMessageSize = maximumMessageSize
        }

        let lifecycleDelegate = FoundationWebSocketLifecycleDelegate()
        task.delegate = lifecycleDelegate

        self.task = task
        self.lifecycleDelegate = lifecycleDelegate
    }

    func setEventHandler(
        _ handler: @escaping @Sendable (WebSocketTaskEvent) -> Void
    ) {
        lifecycleDelegate.setEventHandler(handler)
    }

    func resume() {
        task.resume()
    }

    func send(
        _ message: WebSocketMessage,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        let foundationMessage: URLSessionWebSocketTask.Message
        switch message {
        case .text(let text):
            foundationMessage = .string(text)
        case .binary(let data):
            foundationMessage = .data(data)
        }

        task.send(foundationMessage) { error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    func receive(
        completion: @escaping @Sendable (
            Result<WebSocketMessage, any Error>
        ) -> Void
    ) {
        task.receive { result in
            completion(result.flatMap { message in
                switch message {
                case .string(let text):
                    return .success(.text(text))
                case .data(let data):
                    return .success(.binary(data))
                @unknown default:
                    return .failure(WebSocketError.unsupportedMessage)
                }
            })
        }
    }

    func ping(
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) {
        task.sendPing { error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    func close(code: WebSocketCloseCode, reason: Data?) {
        guard let closeCode = URLSessionWebSocketTask.CloseCode(
            rawValue: code.rawValue
        ) else {
            task.cancel()
            return
        }
        task.cancel(with: closeCode, reason: reason)
    }

    func cancel() {
        task.cancel()
    }

    func closeDetails() -> WebSocketClose? {
        let closeCode = task.closeCode
        guard closeCode != .invalid else { return nil }
        return WebSocketClose(
            code: WebSocketCloseCode(rawValue: closeCode.rawValue),
            reason: task.closeReason
        )
    }

    func handshakeResponse() -> HTTPURLResponse? {
        task.response as? HTTPURLResponse
    }
}

private final class FoundationWebSocketLifecycleDelegate: NSObject,
    URLSessionWebSocketDelegate,
    @unchecked Sendable {
    typealias Handler = @Sendable (WebSocketTaskEvent) -> Void

    private let handler = WebSocketLocked<Handler?>(nil)

    // URLSession forwards only task-delegate methods this object does not
    // implement. Each lifecycle callback below is therefore fanned out to the
    // caller's session delegate after the SDK records it.

    func setEventHandler(_ handler: @escaping Handler) {
        self.handler.withLock { $0 = handler }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        emit(.opened(negotiatedSubprotocol: `protocol`))
        (session.delegate as? URLSessionWebSocketDelegate)?.urlSession?(
            session,
            webSocketTask: webSocketTask,
            didOpenWithProtocol: `protocol`
        )
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        emit(.closed(WebSocketClose(
            code: WebSocketCloseCode(rawValue: closeCode.rawValue),
            reason: reason
        )))
        (session.delegate as? URLSessionWebSocketDelegate)?.urlSession?(
            session,
            webSocketTask: webSocketTask,
            didCloseWith: closeCode,
            reason: reason
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        emit(.completed(error))
        (session.delegate as? URLSessionTaskDelegate)?.urlSession?(
            session,
            task: task,
            didCompleteWithError: error
        )
    }

    private func emit(_ event: WebSocketTaskEvent) {
        handler.withLock { $0 }?(event)
    }
}

// MARK: - Internal transport

enum WebSocketTransportStatus: Sendable {
    case open
    case closed(WebSocketClose?)
}

protocol WebSocketTransport: Sendable {
    func open() async throws -> String?
    func send(_ message: WebSocketMessage) async throws
    func receive() async throws -> WebSocketMessage
    func ping() async throws
    func close(code: WebSocketCloseCode, reason: Data?) async
    func cancel()
    func status() async -> WebSocketTransportStatus
}

final class URLSessionWebSocketTransport: WebSocketTransport,
    @unchecked Sendable {
    private struct LifecycleState: Sendable {
        var openStarted = false
        var didOpen = false
        var isCompleted = false
        var cancelRequested = false
        var close: WebSocketClose?
    }

    private let adapter: any WebSocketTaskAdapter
    private let lifecycle = WebSocketLocked(LifecycleState())
    private let openContinuation = OneShotContinuation<String?>()

    convenience init(
        session: URLSession,
        request: URLRequest,
        maximumMessageSize: Int?
    ) {
        self.init(adapter: FoundationWebSocketTaskAdapter(
            session: session,
            request: request,
            maximumMessageSize: maximumMessageSize
        ))
    }

    init(adapter: any WebSocketTaskAdapter) {
        self.adapter = adapter
        adapter.setEventHandler { [weak self] event in
            self?.handle(event)
        }
    }

    deinit {
        cancel()
    }

    func open() async throws -> String? {
        let shouldStart = lifecycle.withLock { state in
            guard !state.openStarted else { return false }
            state.openStarted = true
            return true
        }
        guard shouldStart else {
            throw WebSocketError.connectionAlreadyStarted
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard openContinuation.install(continuation) else { return }
                if Task.isCancelled {
                    cancel()
                } else {
                    adapter.resume()
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func send(_ message: WebSocketMessage) async throws {
        try await perform { completion in
            self.adapter.send(message, completion: completion)
        }
    }

    func receive() async throws -> WebSocketMessage {
        try await perform { completion in
            self.adapter.receive(completion: completion)
        }
    }

    func ping() async throws {
        try await perform { completion in
            self.adapter.ping(completion: completion)
        }
    }

    func close(code: WebSocketCloseCode, reason: Data?) async {
        adapter.close(code: code, reason: reason)
    }

    func status() async -> WebSocketTransportStatus {
        let taskClose = adapter.closeDetails()
        return lifecycle.withLock { state -> WebSocketTransportStatus in
            if let taskClose {
                state.close = taskClose
                state.isCompleted = true
            }
            if state.isCompleted || state.close != nil {
                return .closed(state.close)
            }
            return .open
        }
    }

    func cancel() {
        let taskClose = adapter.closeDetails()
        let shouldCancel = lifecycle.withLock { state in
            if let taskClose {
                state.close = taskClose
            }
            guard !state.isCompleted, !state.cancelRequested else {
                return false
            }
            state.cancelRequested = true
            state.isCompleted = true
            return true
        }
        if shouldCancel {
            adapter.cancel()
        }
        openContinuation.resolve(.failure(CancellationError()))
    }

    private func perform<Value: Sendable>(
        _ start: @escaping @Sendable (
            @escaping @Sendable (Result<Value, any Error>) -> Void
        ) -> Void
    ) async throws -> Value {
        let continuation = OneShotContinuation<Value>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { checkedContinuation in
                guard continuation.install(checkedContinuation) else { return }
                if Task.isCancelled {
                    cancel()
                    continuation.resolve(.failure(CancellationError()))
                } else {
                    start { result in
                        if case .failure = result {
                            self.markCompleted()
                        }
                        continuation.resolve(result)
                    }
                }
            }
        } onCancel: {
            self.cancel()
            continuation.resolve(.failure(CancellationError()))
        }
    }

    private func handle(_ event: WebSocketTaskEvent) {
        switch event {
        case .opened(let negotiatedSubprotocol):
            lifecycle.withLock { $0.didOpen = true }
            openContinuation.resolve(.success(negotiatedSubprotocol))

        case .closed(let close):
            lifecycle.withLock { state in
                state.close = close
                state.isCompleted = true
            }
            openContinuation.resolve(.failure(
                WebSocketError.connectionClosed(close)
            ))

        case .completed(let error):
            let didOpen = lifecycle.withLock { state in
                state.isCompleted = true
                return state.didOpen
            }
            guard !didOpen else { return }
            if let response = adapter.handshakeResponse() {
                openContinuation.resolve(.failure(
                    WebSocketError.handshakeFailed(
                        metadata: HTTPResponseMetadata(response),
                        underlying: error
                    )
                ))
            } else if let error {
                openContinuation.resolve(.failure(error))
            } else {
                let close = lifecycle.withLock { $0.close }
                openContinuation.resolve(.failure(
                    WebSocketError.connectionClosed(close)
                ))
            }
        }
    }

    private func markCompleted() {
        let taskClose = adapter.closeDetails()
        lifecycle.withLock { state in
            state.isCompleted = true
            if let taskClose {
                state.close = taskClose
            }
        }
    }
}

// MARK: - Public connection actor

public actor WebSocketConnection: WebSocketConnectionProtocol {
    public nonisolated let url: URL
    public nonisolated let negotiatedSubprotocol: String?

    private let transport: any WebSocketTransport
    private var currentState = WebSocketConnectionState.open
    private var receiveInProgress = false

    init(
        url: URL,
        negotiatedSubprotocol: String?,
        transport: any WebSocketTransport
    ) {
        self.url = url
        self.negotiatedSubprotocol = negotiatedSubprotocol
        self.transport = transport
    }

    public var state: WebSocketConnectionState {
        get async {
            await resolvedState()
        }
    }

    public func send(_ message: WebSocketMessage) async throws {
        try await requireOpen()
        do {
            try await transport.send(message)
            try Task.checkCancellation()
        } catch {
            throw await mappedFailure(error)
        }
    }

    public func receive() async throws -> WebSocketMessage {
        try await requireOpen()
        guard !receiveInProgress else {
            throw WebSocketError.concurrentReceive
        }

        receiveInProgress = true
        defer { receiveInProgress = false }

        do {
            let message = try await transport.receive()
            try Task.checkCancellation()
            return message
        } catch {
            throw await mappedFailure(error)
        }
    }

    public func ping() async throws {
        try await requireOpen()
        do {
            try await transport.ping()
            try Task.checkCancellation()
        } catch {
            throw await mappedFailure(error)
        }
    }

    public func close(
        code: WebSocketCloseCode,
        reason: String?
    ) async throws {
        guard code.isValidForSending else {
            throw WebSocketError.invalidCloseCode(code.rawValue)
        }

        let reasonData = reason.map { Data($0.utf8) }
        let maximumReasonBytes = 123
        if let reasonData, reasonData.count > maximumReasonBytes {
            throw WebSocketError.closeReasonTooLong(
                maximumBytes: maximumReasonBytes,
                actualBytes: reasonData.count
            )
        }

        switch await resolvedState() {
        case .open:
            currentState = .closing
            await transport.close(code: code, reason: reasonData)
        case .closing, .closed:
            return
        }
    }

    private func requireOpen() async throws {
        switch await resolvedState() {
        case .open:
            return
        case .closing:
            throw WebSocketError.connectionClosing
        case .closed(let close):
            throw WebSocketError.connectionClosed(close)
        }
    }

    private func resolvedState() async -> WebSocketConnectionState {
        if case .closed(let close) = await transport.status() {
            if case .closed(let existingClose) = currentState,
               existingClose != nil,
               close == nil {
                return currentState
            }
            currentState = .closed(close)
        }
        return currentState
    }

    private func mappedFailure(_ error: any Error) async -> any Error {
        if Task.isCancelled || error is CancellationError {
            transport.cancel()
            currentState = .closed(nil)
            return CancellationError()
        }

        let close: WebSocketClose?
        if case .closed(let value) = await transport.status() {
            close = value
        } else {
            close = nil
        }

        if let webSocketError = error as? WebSocketError {
            if case .connectionClosed(let reportedClose) = webSocketError {
                let resolvedClose = close ?? reportedClose
                currentState = .closed(resolvedClose)
                return WebSocketError.connectionClosed(resolvedClose)
            }
            currentState = .closed(close)
            return webSocketError
        }
        currentState = .closed(close)
        if let close {
            return WebSocketError.connectionClosed(close)
        }
        if let urlError = error as? URLError {
            return WebSocketError.transport(urlError)
        }
        return WebSocketError.unknown(error)
    }
}

// MARK: - Concurrency helpers

private final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    typealias Continuation = CheckedContinuation<Value, any Error>

    private let lock = NSLock()
    private var continuation: Continuation?
    private var pendingResult: Result<Value, any Error>?
    private var isFinished = false

    /// Returns `true` when the caller should start the underlying operation.
    func install(_ continuation: Continuation) -> Bool {
        let pendingResult: Result<Value, any Error>?

        lock.lock()
        if isFinished {
            lock.unlock()
            return false
        }
        if let result = self.pendingResult {
            isFinished = true
            self.pendingResult = nil
            pendingResult = result
        } else {
            self.continuation = continuation
            pendingResult = nil
        }
        lock.unlock()

        if let pendingResult {
            continuation.resume(with: pendingResult)
            return false
        }
        return true
    }

    func resolve(_ result: Result<Value, any Error>) {
        let continuation: Continuation?

        lock.lock()
        if isFinished || pendingResult != nil {
            lock.unlock()
            return
        }
        if let installed = self.continuation {
            isFinished = true
            self.continuation = nil
            continuation = installed
        } else {
            pendingResult = result
            continuation = nil
        }
        lock.unlock()

        continuation?.resume(with: result)
    }
}

private final class WebSocketLocked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func withLock<Result>(
        _ operation: (inout Value) throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation(&value)
    }
}
