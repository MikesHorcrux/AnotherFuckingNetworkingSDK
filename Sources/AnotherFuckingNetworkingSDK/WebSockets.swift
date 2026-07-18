import Foundation

// MARK: - Public request and message types

/// Bounds messages retained by an always-on WebSocket receive pump while the
/// application is not actively receiving.
public struct WebSocketInboundBufferingPolicy:
    Equatable,
    Hashable,
    Sendable {
    /// A balanced mobile default: at most 64 queued messages and 8 MiB of
    /// retained text or binary payload bytes.
    public static let `default` = Self(
        maximumMessages: 64,
        maximumBytes: 8 * 1_024 * 1_024
    )

    /// Maximum number of complete messages retained in the FIFO.
    public let maximumMessages: Int
    /// Aggregate UTF-8 text or binary payload bytes retained in the FIFO.
    public let maximumBytes: Int

    /// Creates limits that are validated when the request is connected.
    /// Both values must be greater than zero.
    public init(maximumMessages: Int, maximumBytes: Int) {
        self.maximumMessages = maximumMessages
        self.maximumBytes = maximumBytes
    }
}

/// Details captured when a slow consumer exceeds its inbound buffering policy.
public struct WebSocketInboundBufferOverflow: Equatable, Sendable {
    public let policy: WebSocketInboundBufferingPolicy
    public let bufferedMessageCount: Int
    public let bufferedByteCount: Int
    public let incomingMessageByteCount: Int

    public init(
        policy: WebSocketInboundBufferingPolicy,
        bufferedMessageCount: Int,
        bufferedByteCount: Int,
        incomingMessageByteCount: Int
    ) {
        self.policy = policy
        self.bufferedMessageCount = bufferedMessageCount
        self.bufferedByteCount = bufferedByteCount
        self.incomingMessageByteCount = incomingMessageByteCount
    }
}

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

    /// Aggregate limits for complete messages retained while no `receive()` is
    /// waiting. The socket closes with a typed error instead of dropping data
    /// when either limit would be exceeded.
    var inboundBufferingPolicy: WebSocketInboundBufferingPolicy { get }

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
    var inboundBufferingPolicy: WebSocketInboundBufferingPolicy { .default }

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
    case invalidInboundBufferingPolicy(WebSocketInboundBufferingPolicy)
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
    case inboundBufferOverflow(WebSocketInboundBufferOverflow)
    case unsupportedMessage
    case transport(URLError)
    case unknown(any Error)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The WebSocket URL is invalid."
        case .invalidMaximumMessageSize(let value):
            return "The maximum WebSocket message size must be positive, not \(value)."
        case .invalidInboundBufferingPolicy(let policy):
            return "WebSocket inbound buffering limits must be positive, not \(policy.maximumMessages) messages and \(policy.maximumBytes) bytes."
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
        case .inboundBufferOverflow(let overflow):
            return "The WebSocket inbound buffer exceeded its \(overflow.policy.maximumMessages)-message or \(overflow.policy.maximumBytes)-byte limit."
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

    /// A newest-only lifecycle sequence. SDK connections push lifecycle
    /// changes, coalesce intermediate states for slow consumers, and finish
    /// after `closed`.
    var states: WebSocketConnectionStates { get }

    /// Sends one complete message.
    ///
    /// Success means Foundation accepted the message for transmission; it is
    /// not an acknowledgement from the peer.
    func send(_ message: WebSocketMessage) async throws

    /// Receives one complete message. Only one receive may be active at once.
    /// Messages already accepted by the bounded receive pump remain drainable
    /// after lifecycle closure; the terminal result follows the retained FIFO.
    func receive() async throws -> WebSocketMessage

    /// Sends a ping and waits for Foundation's pong callback.
    func ping() async throws

    /// Starts a closing handshake without waiting for the peer to complete it.
    func close(code: WebSocketCloseCode, reason: String?) async throws
}

public extension WebSocketConnectionProtocol {
    /// Source-compatible fallback for custom conformers. It emits the current
    /// state once; conformers with push lifecycle events should override it.
    var states: WebSocketConnectionStates {
        WebSocketConnectionStates(currentState: { await self.state })
    }

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

/// A bounded asynchronous sequence of WebSocket lifecycle states.
public struct WebSocketConnectionStates: AsyncSequence, Sendable {
    public typealias Element = WebSocketConnectionState
    public typealias AsyncIterator = AsyncStream<Element>.Iterator

    private let makeStream: @Sendable () -> AsyncStream<Element>

    package init(
        stream: @escaping @Sendable () -> AsyncStream<Element>
    ) {
        makeStream = stream
    }

    fileprivate init(
        currentState: @escaping @Sendable () async -> WebSocketConnectionState
    ) {
        makeStream = {
            AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
                continuation in
                let task = Task {
                    let state = await currentState()
                    if !Task.isCancelled {
                        continuation.yield(state)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        makeStream().makeAsyncIterator()
    }
}

/// An asynchronous sequence that drains one retained message per call to its
/// iterator's `next()` method. Normal and going-away close frames end the
/// sequence after the accepted FIFO; abnormal termination is then thrown.
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
    package struct PreparedRequest {
        package let urlRequest: URLRequest
        package let subprotocols: [String]
        package let transportConfiguration: WebSocketTransportConfiguration
    }

    private struct RequestOptions {
        let headers: [String: String]?
        let subprotocols: [String]
        let maximumMessageSize: Int?
        let inboundBufferingPolicy: WebSocketInboundBufferingPolicy
    }

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
        try prepare(
            request,
            baseURL: baseURL,
            globalHeaders: globalHeaders
        ).urlRequest
    }

    /// Snapshots transport-affecting request options once so validation and
    /// transport construction cannot observe different values from a
    /// synchronized mutable request conformer.
    package static func prepare<R: WebSocketRequest>(
        _ request: R,
        baseURL: URL?,
        globalHeaders: [String: String]
    ) throws -> PreparedRequest {
        let options = RequestOptions(
            headers: request.headers,
            subprotocols: request.subprotocols,
            maximumMessageSize: request.maximumMessageSize,
            inboundBufferingPolicy: request.inboundBufferingPolicy
        )

        guard let baseURL,
              let unresolvedURL = request.makeURL(baseURL: baseURL),
              let webSocketURL = webSocketURL(from: unresolvedURL) else {
            throw WebSocketError.invalidURL
        }

        if let maximumMessageSize = options.maximumMessageSize,
           maximumMessageSize <= 0 {
            throw WebSocketError.invalidMaximumMessageSize(maximumMessageSize)
        }

        let bufferingPolicy = options.inboundBufferingPolicy
        guard bufferingPolicy.maximumMessages > 0,
              bufferingPolicy.maximumBytes > 0 else {
            throw WebSocketError.invalidInboundBufferingPolicy(bufferingPolicy)
        }

        try validate(subprotocols: options.subprotocols)

        var headers = normalizedHeaders(globalHeaders)
        for (name, value) in normalizedHeaders(options.headers ?? [:]) {
            headers[name] = value
        }
        try validateCallerHeaders(headers)

        var urlRequest = URLRequest(url: webSocketURL)
        urlRequest.httpMethod = HTTPMethod.get.rawValue
        for (name, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let expectedSubprotocolHeader: String?
        if options.subprotocols.isEmpty {
            expectedSubprotocolHeader = nil
        } else {
            let header = options.subprotocols.joined(separator: ", ")
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
        return PreparedRequest(
            urlRequest: urlRequest,
            subprotocols: options.subprotocols,
            transportConfiguration: WebSocketTransportConfiguration(
                maximumMessageSize: options.maximumMessageSize,
                inboundBufferingPolicy: bufferingPolicy
            )
        )
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
    case metrics(NetworkTaskMetricsSnapshot)
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

    private let handler = CriticalState<Handler?>(nil)

    // URLSession forwards only task-delegate methods this object does not
    // implement. Each lifecycle callback below is therefore fanned out to the
    // caller's session delegate after the SDK records it.

    func setEventHandler(_ handler: @escaping Handler) {
        self.handler.withCriticalRegion { $0 = handler }
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

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        emit(.metrics(NetworkTaskMetricsSnapshot(metrics)))
        (session.delegate as? URLSessionTaskDelegate)?.urlSession?(
            session,
            task: task,
            didFinishCollecting: metrics
        )
    }

    private func emit(_ event: WebSocketTaskEvent) {
        handler.withCriticalRegion { $0 }?(event)
    }
}

// MARK: - Internal transport

protocol WebSocketTaskMetricsReporting: AnyObject, Sendable {
    func setTaskMetricsHandler(
        _ handler: @escaping @Sendable (NetworkTaskMetricsSnapshot) -> Void
    )
}

enum WebSocketTransportStatus: Sendable {
    case open
    case closed(WebSocketClose?)
}

protocol WebSocketTransport: Sendable {
    func open() async throws -> String?
    func send(_ message: WebSocketMessage) async throws
    func receive() async throws -> WebSocketMessage
    func ping() async throws
    func close(code: WebSocketCloseCode, reason: Data?)
    func cancel()
    func status() -> WebSocketTransportStatus
    func stateStream() -> AsyncStream<WebSocketConnectionState>
}

extension WebSocketTransport {
    func stateStream() -> AsyncStream<WebSocketConnectionState> {
        let status = status()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            continuation in
            switch status {
            case .open:
                continuation.yield(.open)
            case .closed(let close):
                continuation.yield(.closed(close))
            }
            continuation.finish()
        }
    }
}

private extension WebSocketMessage {
    var inboundBufferedByteCount: Int {
        switch self {
        case .text(let text):
            return text.utf8.count
        case .binary(let data):
            return data.count
        }
    }
}

final class URLSessionWebSocketTransport: WebSocketTransport,
    WebSocketTaskMetricsReporting,
    @unchecked Sendable {
    private struct BufferedMessage: Sendable {
        let message: WebSocketMessage
        let byteCount: Int
    }

    /// An amortized O(1) FIFO that avoids shifting retained payloads on every
    /// receive. Storage is compacted only after a meaningful consumed prefix.
    private struct MessageQueue: Sendable {
        private var storage: [BufferedMessage?] = []
        private var headIndex = 0

        var count: Int { storage.count - headIndex }

        mutating func append(_ element: BufferedMessage) {
            storage.append(element)
        }

        mutating func popFirst(
            releaseStorageWhenEmpty: Bool
        ) -> BufferedMessage? {
            guard headIndex < storage.count,
                  let element = storage[headIndex] else {
                return nil
            }
            storage[headIndex] = nil
            headIndex += 1

            if headIndex == storage.count {
                storage.removeAll(keepingCapacity: !releaseStorageWhenEmpty)
                headIndex = 0
            } else if headIndex >= 64,
                      headIndex >= storage.count / 2 {
                storage.removeFirst(headIndex)
                headIndex = 0
            }
            return element
        }
    }

    private struct LifecycleState: Sendable {
        var openStarted = false
        var didOpen = false
        var isCompleted = false
        var cancelRequested = false
        var localCloseRequested = false
        var close: WebSocketClose?
        var receivePumpStarted = false
        var receiveDriverActive = false
        var receiveOutstanding = false
        var receiveWaiter: OneShotContinuation<WebSocketMessage>?
        var bufferedMessages = MessageQueue()
        var bufferedByteCount = 0
        var pendingReceiveFailure: (any Error)?
        var terminalReceiveError: (any Error)?
    }

    private struct TerminalAction {
        let waiter: OneShotContinuation<WebSocketMessage>?
        let error: any Error
        let close: WebSocketClose?
        let shouldCancel: Bool
    }

    private enum ReceiveSuccessAction {
        case ignored
        case accepted(
            waiter: OneShotContinuation<WebSocketMessage>?,
            shouldDrive: Bool
        )
        case overflow(
            WebSocketInboundBufferOverflow,
            close: WebSocketClose?,
            shouldCancel: Bool
        )
    }

    private let adapter: any WebSocketTaskAdapter
    private let taskMetricsHandler = CriticalState<(
        @Sendable (NetworkTaskMetricsSnapshot) -> Void
    )?>(nil)
    private let inboundBufferingPolicy: WebSocketInboundBufferingPolicy
    private let lifecycle = CriticalState(LifecycleState())
    private let openContinuation = OneShotContinuation<String?>()
    private let stateBroadcaster = LatestValueBroadcaster<
        WebSocketConnectionState
    >(.open)

    convenience init(
        session: URLSession,
        request: URLRequest,
        maximumMessageSize: Int?,
        inboundBufferingPolicy: WebSocketInboundBufferingPolicy = .default
    ) {
        self.init(
            adapter: FoundationWebSocketTaskAdapter(
                session: session,
                request: request,
                maximumMessageSize: maximumMessageSize
            ),
            inboundBufferingPolicy: inboundBufferingPolicy
        )
    }

    init(
        adapter: any WebSocketTaskAdapter,
        inboundBufferingPolicy: WebSocketInboundBufferingPolicy = .default
    ) {
        precondition(inboundBufferingPolicy.maximumMessages > 0)
        precondition(inboundBufferingPolicy.maximumBytes > 0)
        self.adapter = adapter
        self.inboundBufferingPolicy = inboundBufferingPolicy
        adapter.setEventHandler { [weak self] event in
            self?.handle(event)
        }
    }

    func setTaskMetricsHandler(
        _ handler: @escaping @Sendable (NetworkTaskMetricsSnapshot) -> Void
    ) {
        taskMetricsHandler.withCriticalRegion { $0 = handler }
    }

    deinit {
        cancel()
    }

    func open() async throws -> String? {
        let shouldStart = lifecycle.withCriticalRegion { state in
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
        let operation = OneShotContinuation<WebSocketMessage>()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard operation.install(continuation) else { return }
                if Task.isCancelled {
                    operation.resolve(.failure(CancellationError()))
                    cancel()
                    return
                }

                let immediateResult = lifecycle.withCriticalRegion {
                    state -> Result<WebSocketMessage, any Error>? in
                    if let buffered = state.bufferedMessages.popFirst(
                        releaseStorageWhenEmpty: state.isCompleted
                    ) {
                        state.bufferedByteCount -= buffered.byteCount
                        return .success(buffered.message)
                    }
                    if state.isCompleted {
                        return .failure(
                            state.terminalReceiveError
                                ?? WebSocketError.connectionClosed(state.close)
                        )
                    }
                    guard state.receiveWaiter == nil else {
                        return .failure(WebSocketError.concurrentReceive)
                    }
                    state.receiveWaiter = operation
                    return nil
                }
                if let immediateResult {
                    operation.resolve(immediateResult)
                }
            }
        } onCancel: {
            operation.resolve(.failure(CancellationError()))
            self.cancel()
        }
    }

    func ping() async throws {
        try await perform { completion in
            self.adapter.ping(completion: completion)
        }
    }

    func close(code: WebSocketCloseCode, reason: Data?) {
        let shouldClose = lifecycle.withCriticalRegion { state in
            guard !state.isCompleted, !state.localCloseRequested else {
                return false
            }
            state.localCloseRequested = true
            return true
        }
        guard shouldClose else { return }
        stateBroadcaster.publish(.closing)
        adapter.close(code: code, reason: reason)
    }

    func status() -> WebSocketTransportStatus {
        let taskClose = adapter.closeDetails()
        let observation = lifecycle.withCriticalRegion { state -> (
            status: WebSocketTransportStatus,
            waiter: OneShotContinuation<WebSocketMessage>?,
            error: (any Error)?
        ) in
            if let taskClose {
                state.close = taskClose
                state.isCompleted = true
                state.receivePumpStarted = false
                state.receiveDriverActive = false
                state.receiveOutstanding = false
                state.pendingReceiveFailure = nil
                state.terminalReceiveError = Self.terminalError(
                    preserving: state.terminalReceiveError,
                    close: taskClose
                )
                let waiter = state.receiveWaiter
                state.receiveWaiter = nil
                return (
                    .closed(taskClose),
                    waiter,
                    state.terminalReceiveError
                )
            }
            if state.isCompleted || state.close != nil {
                return (.closed(state.close), nil, nil)
            }
            return (.open, nil, nil)
        }
        if let taskClose {
            stateBroadcaster.finish(with: .closed(taskClose))
        }
        if let waiter = observation.waiter,
           let error = observation.error {
            waiter.resolve(.failure(error))
        }
        return observation.status
    }

    func stateStream() -> AsyncStream<WebSocketConnectionState> {
        stateBroadcaster.stream()
    }

    func cancel() {
        let taskClose = adapter.closeDetails()
        let cancellation = lifecycle.withCriticalRegion { state in
            if let taskClose {
                state.close = taskClose
            }
            guard !state.isCompleted, !state.cancelRequested else {
                return TerminalAction(
                    waiter: nil,
                    error: WebSocketError.connectionClosed(state.close),
                    close: state.close,
                    shouldCancel: false
                )
            }
            state.cancelRequested = true
            state.isCompleted = true
            state.receivePumpStarted = false
            state.receiveDriverActive = false
            state.receiveOutstanding = false
            state.pendingReceiveFailure = nil
            if state.terminalReceiveError == nil {
                state.terminalReceiveError =
                    WebSocketError.connectionClosed(state.close)
            }
            let waiter = state.receiveWaiter
            state.receiveWaiter = nil
            return TerminalAction(
                waiter: waiter,
                error: state.terminalReceiveError
                    ?? WebSocketError.connectionClosed(state.close),
                close: state.close,
                shouldCancel: true
            )
        }
        if cancellation.shouldCancel {
            adapter.cancel()
            stateBroadcaster.finish(with: .closed(cancellation.close))
        }
        cancellation.waiter?.resolve(.failure(cancellation.error))
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
                    continuation.resolve(.failure(CancellationError()))
                    cancel()
                } else {
                    start { result in
                        if case .failure(let error) = result {
                            self.markCompleted(error: error)
                        }
                        continuation.resolve(result)
                    }
                }
            }
        } onCancel: {
            continuation.resolve(.failure(CancellationError()))
            self.cancel()
        }
    }

    private func handle(_ event: WebSocketTaskEvent) {
        switch event {
        case .opened(let negotiatedSubprotocol):
            let opening = lifecycle.withCriticalRegion { state -> (
                accepted: Bool,
                shouldDrive: Bool
            ) in
                guard !state.isCompleted, !state.didOpen else {
                    return (false, false)
                }
                state.didOpen = true
                openContinuation.resolve(.success(negotiatedSubprotocol))
                state.receivePumpStarted = true
                guard !state.receiveDriverActive else {
                    return (true, false)
                }
                state.receiveDriverActive = true
                return (true, true)
            }
            guard opening.accepted else { return }
            stateBroadcaster.publish(.open)
            if opening.shouldDrive {
                driveReceivePump()
            }

        case .closed(let close):
            let closure = lifecycle.withCriticalRegion { state in
                state.close = close
                state.isCompleted = true
                state.receivePumpStarted = false
                state.receiveDriverActive = false
                state.receiveOutstanding = false
                state.pendingReceiveFailure = nil
                state.terminalReceiveError = Self.terminalError(
                    preserving: state.terminalReceiveError,
                    close: close
                )
                if !state.didOpen {
                    openContinuation.resolve(.failure(
                        WebSocketError.connectionClosed(close)
                    ))
                }
                let waiter = state.receiveWaiter
                state.receiveWaiter = nil
                return TerminalAction(
                    waiter: waiter,
                    error: state.terminalReceiveError
                        ?? WebSocketError.connectionClosed(close),
                    close: close,
                    shouldCancel: false
                )
            }
            stateBroadcaster.finish(with: .closed(close))
            closure.waiter?.resolve(.failure(closure.error))

        case .completed(let error):
            let taskClose = adapter.closeDetails()
            let handshakeResponse = adapter.handshakeResponse()
            let completion = lifecycle.withCriticalRegion { state in
                if let taskClose {
                    state.close = taskClose
                }
                state.isCompleted = true
                state.receivePumpStarted = false
                state.receiveDriverActive = false
                state.receiveOutstanding = false
                if state.terminalReceiveError == nil {
                    state.terminalReceiveError = state.close.map {
                        WebSocketError.connectionClosed($0)
                    } ?? error ?? state.pendingReceiveFailure
                        ?? WebSocketError.connectionClosed(nil)
                }
                state.pendingReceiveFailure = nil
                if !state.didOpen {
                    let openingError: any Error
                    if let handshakeResponse {
                        openingError = WebSocketError.handshakeFailed(
                            metadata: HTTPResponseMetadata(handshakeResponse),
                            underlying: error
                        )
                    } else if let error {
                        openingError = error
                    } else {
                        openingError = WebSocketError.connectionClosed(
                            state.close
                        )
                    }
                    openContinuation.resolve(.failure(openingError))
                }
                let waiter = state.receiveWaiter
                state.receiveWaiter = nil
                return (
                    close: state.close,
                    waiter: waiter,
                    receiveError: state.terminalReceiveError
                        ?? WebSocketError.connectionClosed(state.close)
                )
            }
            stateBroadcaster.finish(with: .closed(completion.close))
            completion.waiter?.resolve(.failure(completion.receiveError))

        case .metrics(let snapshot):
            taskMetricsHandler.withCriticalRegion { $0 }?(snapshot)
        }
    }

    private func driveReceivePump() {
        while true {
            let shouldReceive = lifecycle.withCriticalRegion { state -> Bool in
                guard state.receiveDriverActive,
                      state.receivePumpStarted,
                      !state.isCompleted,
                      !state.receiveOutstanding else {
                    state.receiveDriverActive = false
                    return false
                }
                state.receiveOutstanding = true
                return true
            }
            guard shouldReceive else { return }

            adapter.receive { [weak self] result in
                self?.handleReceiveResult(result)
            }

            let completedSynchronously = lifecycle.withCriticalRegion {
                state -> Bool in
                guard state.receivePumpStarted, !state.isCompleted else {
                    state.receiveDriverActive = false
                    return false
                }
                if state.receiveOutstanding {
                    state.receiveDriverActive = false
                    return false
                }
                return true
            }
            guard completedSynchronously else { return }
        }
    }

    private func handleReceiveResult(
        _ result: Result<WebSocketMessage, any Error>
    ) {
        switch result {
        case .success(let message):
            handleReceivedMessage(message)
        case .failure(let error):
            handleReceiveFailure(error)
        }
    }

    private func handleReceivedMessage(_ message: WebSocketMessage) {
        let byteCount = message.inboundBufferedByteCount
        let action = lifecycle.withCriticalRegion {
            state -> ReceiveSuccessAction in
            guard state.receiveOutstanding else { return .ignored }
            state.receiveOutstanding = false
            guard !state.isCompleted else { return .ignored }

            if let waiter = state.receiveWaiter {
                state.receiveWaiter = nil
                let shouldDrive = claimReceiveDriverIfNeeded(&state)
                return .accepted(waiter: waiter, shouldDrive: shouldDrive)
            }

            let exceedsMessages = state.bufferedMessages.count
                >= inboundBufferingPolicy.maximumMessages
            let exceedsBytes = byteCount
                > inboundBufferingPolicy.maximumBytes
                || state.bufferedByteCount
                    > inboundBufferingPolicy.maximumBytes - byteCount
            if exceedsMessages || exceedsBytes {
                let overflow = WebSocketInboundBufferOverflow(
                    policy: inboundBufferingPolicy,
                    bufferedMessageCount: state.bufferedMessages.count,
                    bufferedByteCount: state.bufferedByteCount,
                    incomingMessageByteCount: byteCount
                )
                state.isCompleted = true
                state.receivePumpStarted = false
                state.terminalReceiveError =
                    WebSocketError.inboundBufferOverflow(overflow)
                let shouldCancel = !state.cancelRequested
                state.cancelRequested = true
                return .overflow(
                    overflow,
                    close: state.close,
                    shouldCancel: shouldCancel
                )
            }

            state.bufferedMessages.append(BufferedMessage(
                message: message,
                byteCount: byteCount
            ))
            state.bufferedByteCount += byteCount
            let shouldDrive = claimReceiveDriverIfNeeded(&state)
            return .accepted(waiter: nil, shouldDrive: shouldDrive)
        }

        switch action {
        case .ignored:
            return
        case .accepted(let waiter, let shouldDrive):
            waiter?.resolve(.success(message))
            if shouldDrive {
                driveReceivePump()
            }
        case .overflow(_, let close, let shouldCancel):
            if shouldCancel {
                adapter.cancel()
            }
            stateBroadcaster.finish(with: .closed(close))
        }
    }

    private func handleReceiveFailure(_ error: any Error) {
        let taskClose = adapter.closeDetails()
        let completion = lifecycle.withCriticalRegion {
            state -> TerminalAction? in
            guard state.receiveOutstanding else { return nil }
            state.receiveOutstanding = false
            guard !state.isCompleted else { return nil }
            state.receivePumpStarted = false
            state.receiveDriverActive = false
            guard let taskClose else {
                // URLSession reports task completion or a close delegate event
                // after a receive callback fails. Preserve the callback error
                // provisionally so a close frame arriving next can refine it.
                state.pendingReceiveFailure = error
                return nil
            }
            state.isCompleted = true
            state.close = taskClose
            state.pendingReceiveFailure = nil
            let receiveError = WebSocketError.connectionClosed(taskClose)
            state.terminalReceiveError = Self.terminalError(
                preserving: state.terminalReceiveError,
                close: taskClose
            )
            let waiter = state.receiveWaiter
            state.receiveWaiter = nil
            return TerminalAction(
                waiter: waiter,
                error: state.terminalReceiveError ?? receiveError,
                close: state.close,
                shouldCancel: false
            )
        }
        guard let completion else { return }
        if completion.shouldCancel {
            adapter.cancel()
        }
        stateBroadcaster.finish(with: .closed(completion.close))
        completion.waiter?.resolve(.failure(completion.error))
    }

    private func markCompleted(error: any Error) {
        let taskClose = adapter.closeDetails()
        let completion = lifecycle.withCriticalRegion { state in
            if let taskClose {
                state.close = taskClose
            }
            guard !state.isCompleted else {
                return TerminalAction(
                    waiter: nil,
                    error: error,
                    close: state.close,
                    shouldCancel: false
                )
            }
            state.isCompleted = true
            state.receivePumpStarted = false
            state.receiveDriverActive = false
            state.receiveOutstanding = false
            state.pendingReceiveFailure = nil
            let receiveError: any Error = taskClose.map {
                WebSocketError.connectionClosed($0)
            } ?? error
            if state.terminalReceiveError == nil {
                state.terminalReceiveError = receiveError
            }
            let waiter = state.receiveWaiter
            state.receiveWaiter = nil
            let shouldCancel = taskClose == nil && !state.cancelRequested
            if shouldCancel {
                state.cancelRequested = true
            }
            return TerminalAction(
                waiter: waiter,
                error: state.terminalReceiveError ?? receiveError,
                close: state.close,
                shouldCancel: shouldCancel
            )
        }
        if completion.shouldCancel {
            adapter.cancel()
        }
        stateBroadcaster.finish(with: .closed(completion.close))
        completion.waiter?.resolve(.failure(completion.error))
    }

    private static func terminalError(
        preserving existing: (any Error)?,
        close: WebSocketClose?
    ) -> any Error {
        if let webSocketError = existing as? WebSocketError,
           case .inboundBufferOverflow = webSocketError {
            return webSocketError
        }
        return WebSocketError.connectionClosed(close)
    }

    private func claimReceiveDriverIfNeeded(
        _ state: inout LifecycleState
    ) -> Bool {
        guard state.receivePumpStarted,
              !state.isCompleted,
              !state.receiveDriverActive else {
            return false
        }
        state.receiveDriverActive = true
        return true
    }
}

// MARK: - Public connection actor

public actor WebSocketConnection: WebSocketConnectionProtocol {
    public nonisolated let url: URL
    public nonisolated let negotiatedSubprotocol: String?

    private nonisolated let transport: any WebSocketTransport
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
            resolvedState()
        }
    }

    public nonisolated var states: WebSocketConnectionStates {
        let transport = self.transport
        return WebSocketConnectionStates(stream: {
            transport.stateStream()
        })
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
        if case .closing = resolvedState() {
            throw WebSocketError.connectionClosing
        }
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

        switch resolvedState() {
        case .open:
            currentState = .closing
            transport.close(code: code, reason: reasonData)
        case .closing, .closed:
            return
        }
    }

    private func requireOpen() async throws {
        switch resolvedState() {
        case .open:
            return
        case .closing:
            throw WebSocketError.connectionClosing
        case .closed(let close):
            throw WebSocketError.connectionClosed(close)
        }
    }

    private func resolvedState() -> WebSocketConnectionState {
        if case .closed(let close) = transport.status() {
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
        if case .closed(let value) = transport.status() {
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

private final class OneShotContinuation<Value: Sendable>: Sendable {
    typealias Continuation = CheckedContinuation<Value, any Error>

    private struct State: Sendable {
        var continuation: Continuation?
        var pendingResult: Result<Value, any Error>?
        var isFinished = false
    }

    private let state = CriticalState(State())

    /// Returns `true` when the caller should start the underlying operation.
    func install(_ continuation: Continuation) -> Bool {
        let installation = state.withCriticalRegion { state -> (
            shouldStart: Bool,
            pendingResult: Result<Value, any Error>?
        ) in
            guard !state.isFinished else { return (false, nil) }
            if let result = state.pendingResult {
                state.isFinished = true
                state.pendingResult = nil
                return (false, result)
            }
            state.continuation = continuation
            return (true, nil)
        }

        if let pendingResult = installation.pendingResult {
            continuation.resume(with: pendingResult)
        }
        return installation.shouldStart
    }

    func resolve(_ result: Result<Value, any Error>) {
        let continuation = state.withCriticalRegion { state -> Continuation? in
            guard !state.isFinished, state.pendingResult == nil else {
                return nil
            }
            if let installed = state.continuation {
                state.isFinished = true
                state.continuation = nil
                return installed
            }
            state.pendingResult = result
            return nil
        }

        continuation?.resume(with: result)
    }
}
