import Foundation
import AnotherFuckingNetworkingSDK

/// A structured, concurrency-safe record of a mock WebSocket connection
/// request.
public struct RecordedWebSocketRequest: Equatable, Sendable {
    public let sequenceID: Int
    public let requestTypeID: ObjectIdentifier
    public let requestTypeName: String

    /// The fully constructed handshake request used for exact matching.
    public let urlRequest: URLRequest

    /// The final WebSocket URL after URL construction and customization.
    public let url: URL

    /// The request's declared path before it is resolved against ``url``.
    public let path: String

    /// Query items from the final URL.
    public let queryItems: [URLQueryItem]

    /// Final handshake headers, keyed by lowercase field name.
    public let headers: [String: String]

    /// Ordered application subprotocols requested by the caller.
    public let subprotocols: [String]

    /// The requested maximum received message size.
    public let maximumMessageSize: Int?

    /// Creates a structured record of one mock WebSocket invocation.
    public init(
        sequenceID: Int,
        requestTypeID: ObjectIdentifier,
        requestTypeName: String,
        urlRequest: URLRequest,
        url: URL,
        path: String,
        queryItems: [URLQueryItem],
        headers: [String: String],
        subprotocols: [String],
        maximumMessageSize: Int?
    ) {
        self.sequenceID = sequenceID
        self.requestTypeID = requestTypeID
        self.requestTypeName = requestTypeName
        self.urlRequest = urlRequest
        self.url = url
        self.path = path
        self.queryItems = queryItems
        self.headers = headers
        self.subprotocols = subprotocols
        self.maximumMessageSize = maximumMessageSize
    }
}

/// An error produced when a mock cannot satisfy a WebSocket request.
public enum MockWebSocketClientError: LocalizedError, Equatable, Sendable {
    case missingStub(RecordedWebSocketRequest)

    public var errorDescription: String? {
        switch self {
        case .missingStub(let request):
            return "No WebSocket stub is registered for \(request.requestTypeName) at \(request.path)."
        }
    }
}

/// A deterministic, actor-isolated test double for
/// ``WebSocketClientProtocol``.
///
/// Exact request stubs take precedence over type-wide defaults. Register a
/// factory when each connection should have independent state; the connection
/// overloads are conveniences for tests that intentionally reuse one instance.
public actor MockWebSocketClient: WebSocketClientProtocol {
    public typealias Sleeper = @Sendable (UInt64) async throws -> Void
    public typealias ConnectionFactory = @Sendable (
        any WebSocketRequest
    ) async throws -> any WebSocketConnectionProtocol

    public private(set) var recordedRequests: [RecordedWebSocketRequest] = []

    private let baseURL: URL
    private let globalHeaders: [String: String]
    private var delayNanoseconds: UInt64
    private let sleeper: Sleeper
    private var stubs: [StubRegistration] = []

    /// Creates a mock whose handshake construction mirrors a production
    /// client.
    ///
    /// - Parameters:
    ///   - baseURL: The URL used by request URL builders. Defaults to an
    ///     isolated `https://mock.invalid` origin.
    ///   - globalHeaders: Headers applied before request-specific overrides.
    ///   - delay: An optional simulated delay in seconds.
    ///   - sleeper: The wait implementation, injectable for deterministic
    ///     tests.
    public init(
        baseURL: URL? = nil,
        globalHeaders: [String: String] = [:],
        delay: TimeInterval = 0,
        sleeper: @escaping Sleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.baseURL = baseURL ?? URL(string: "https://mock.invalid")!
        self.globalHeaders = globalHeaders
        delayNanoseconds = Self.nanoseconds(for: delay)
        self.sleeper = sleeper
    }

    // MARK: Factory stubs

    /// Registers a type-wide factory. The factory runs once per connection.
    public func stub<R: WebSocketRequest>(
        _ requestType: R.Type,
        factory: @escaping ConnectionFactory
    ) {
        register(
            requestType,
            signature: nil,
            stub: .factory(factory)
        )
    }

    /// Registers a factory for one fully constructed handshake request.
    public func stub<R: WebSocketRequest>(
        _ request: R,
        factory: @escaping ConnectionFactory
    ) throws {
        try registerExact(request, stub: .factory(factory))
    }

    // MARK: Connection conveniences

    /// Registers one connection for all requests of the supplied type.
    public func stub<R: WebSocketRequest>(
        _ requestType: R.Type,
        with connection: any WebSocketConnectionProtocol
    ) {
        stub(requestType) { _ in connection }
    }

    /// Registers one connection for an exact handshake request.
    public func stub<R: WebSocketRequest>(
        _ request: R,
        with connection: any WebSocketConnectionProtocol
    ) throws {
        try stub(request) { _ in connection }
    }

    // MARK: Failure stubs

    /// Registers an error for all requests of the supplied type.
    public func stubError<R: WebSocketRequest>(
        _ requestType: R.Type,
        error: any Error
    ) {
        register(requestType, signature: nil, stub: .failure(error))
    }

    /// Registers an error for one fully constructed handshake request.
    public func stubError<R: WebSocketRequest>(
        _ request: R,
        error: any Error
    ) throws {
        try registerExact(request, stub: .failure(error))
    }

    // MARK: State management

    public func setDelay(_ delay: TimeInterval) {
        delayNanoseconds = Self.nanoseconds(for: delay)
    }

    public func clearStubs() {
        stubs.removeAll(keepingCapacity: true)
    }

    public func clearRecordedRequests() {
        recordedRequests.removeAll(keepingCapacity: true)
    }

    public func reset() {
        clearStubs()
        clearRecordedRequests()
        delayNanoseconds = 0
    }

    // MARK: WebSocketClientProtocol

    public func connect<R: WebSocketRequest>(
        _ request: R
    ) async throws -> any WebSocketConnectionProtocol {
        try Task.checkCancellation()

        let context = try makeContext(for: request)
        let invocation = record(request, context: context)
        let resolvedStub = resolve(
            R.self,
            signature: context.signature
        )
        let delay = delayNanoseconds

        try await wait(delay)

        guard let resolvedStub else {
            throw MockWebSocketClientError.missingStub(invocation)
        }

        switch resolvedStub {
        case .factory(let factory):
            do {
                let connection = try await factory(request)
                try Task.checkCancellation()
                return connection
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                throw error
            }

        case .failure(let error):
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    private func wait(_ nanoseconds: UInt64) async throws {
        try Task.checkCancellation()
        if nanoseconds > 0 {
            do {
                try await sleeper(nanoseconds)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                throw error
            }
        }
        try Task.checkCancellation()
    }

    private func register<R: WebSocketRequest>(
        _ requestType: R.Type,
        signature: Signature?,
        stub: Stub
    ) {
        stubs.append(StubRegistration(
            requestType: ObjectIdentifier(requestType),
            signature: signature,
            stub: stub
        ))
    }

    private func registerExact<R: WebSocketRequest>(
        _ request: R,
        stub: Stub
    ) throws {
        let context = try makeContext(for: request)
        register(R.self, signature: context.signature, stub: stub)
    }

    private func resolve<R: WebSocketRequest>(
        _ requestType: R.Type,
        signature: Signature
    ) -> Stub? {
        let requestTypeID = ObjectIdentifier(requestType)

        if let exact = stubs.last(where: { registration in
            registration.requestType == requestTypeID
                && registration.signature == signature
        }) {
            return exact.stub
        }

        return stubs.last(where: { registration in
            registration.requestType == requestTypeID
                && registration.signature == nil
        })?.stub
    }

    private func makeContext<R: WebSocketRequest>(
        for request: R
    ) throws -> RequestContext {
        let urlRequest = try WebSocketRequestBuilder.make(
            request,
            baseURL: baseURL,
            globalHeaders: globalHeaders
        )
        guard let url = urlRequest.url else {
            throw WebSocketError.invalidURL
        }

        return RequestContext(
            urlRequest: urlRequest,
            url: url,
            signature: Signature(
                urlRequest: urlRequest,
                maximumMessageSize: request.maximumMessageSize,
                subprotocols: request.subprotocols
            )
        )
    }

    @discardableResult
    private func record<R: WebSocketRequest>(
        _ request: R,
        context: RequestContext
    ) -> RecordedWebSocketRequest {
        let invocation = RecordedWebSocketRequest(
            sequenceID: recordedRequests.count,
            requestTypeID: ObjectIdentifier(R.self),
            requestTypeName: String(reflecting: R.self),
            urlRequest: context.urlRequest,
            url: context.url,
            path: request.path,
            queryItems: URLComponents(
                url: context.url,
                resolvingAgainstBaseURL: false
            )?.queryItems ?? [],
            headers: Self.normalizedHeaders(
                context.urlRequest.allHTTPHeaderFields ?? [:]
            ),
            subprotocols: request.subprotocols,
            maximumMessageSize: request.maximumMessageSize
        )
        recordedRequests.append(invocation)
        return invocation
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

    private static func nanoseconds(for delay: TimeInterval) -> UInt64 {
        guard delay.isFinite, delay > 0 else { return 0 }
        let scaled = delay * 1_000_000_000
        guard scaled < Double(UInt64.max) else { return UInt64.max }
        return UInt64(scaled.rounded(.towardZero))
    }
}

private extension MockWebSocketClient {
    enum Stub: Sendable {
        case factory(ConnectionFactory)
        case failure(any Error)
    }

    struct StubRegistration: Sendable {
        let requestType: ObjectIdentifier
        let signature: Signature?
        let stub: Stub
    }

    struct RequestContext: Sendable {
        let urlRequest: URLRequest
        let url: URL
        let signature: Signature
    }

    struct Signature: Equatable, Sendable {
        let urlRequest: URLRequest
        let maximumMessageSize: Int?
        let subprotocols: [String]
    }
}
