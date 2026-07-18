import Foundation
import AnotherFuckingNetworkingSDK

/// The kind of client operation captured by a mock invocation.
public enum MockRequestOperation: String, Equatable, Sendable {
    case request
    case page
}

/// A structured, concurrency-safe record of a mock client invocation.
public struct RecordedRequest: Equatable, Sendable {
    public let sequenceID: Int
    public let operation: MockRequestOperation
    public let requestTypeID: ObjectIdentifier
    public let requestTypeName: String
    public let method: HTTPMethod

    /// The final URL after custom URL construction and pagination are applied.
    public let url: URL

    /// The request's declared path before it is resolved against ``url``.
    public let path: String

    /// Query items from ``url``, including pagination items for page sends.
    public let queryItems: [URLQueryItem]
    public let headers: [String: String]

    /// The body returned by ``Request/makeBody(using:)``.
    public let body: Data?
    public let page: Int?
    public let pageSize: Int?

    /// Creates a mock whose request construction mirrors a production client.
    ///
    /// - Parameters:
    ///   - baseURL: The URL used by request URL builders. Defaults to an
    ///     isolated `https://mock.invalid` origin.
    ///   - encoderFactory: Creates the encoder used for matching and recording.
    ///   - delay: An optional simulated delay in seconds.
    ///   - sleeper: The wait implementation, injectable for deterministic tests.
    public init(
        sequenceID: Int,
        operation: MockRequestOperation,
        requestTypeID: ObjectIdentifier,
        requestTypeName: String,
        method: HTTPMethod,
        url: URL,
        path: String,
        queryItems: [URLQueryItem],
        headers: [String: String],
        body: Data?,
        page: Int?,
        pageSize: Int?
    ) {
        self.sequenceID = sequenceID
        self.operation = operation
        self.requestTypeID = requestTypeID
        self.requestTypeName = requestTypeName
        self.method = method
        self.url = url
        self.path = path
        self.queryItems = queryItems
        self.headers = headers
        self.body = body
        self.page = page
        self.pageSize = pageSize
    }
}

/// An error produced when a mock cannot satisfy a recorded request.
public enum MockAPIClientError: LocalizedError, Equatable, Sendable {
    case missingStub(RecordedRequest)
    case responseTypeMismatch(RecordedRequest)

    public var errorDescription: String? {
        switch self {
        case .missingStub(let request):
            return "No \(request.operation.rawValue) stub is registered for \(request.requestTypeName) at \(request.path)."
        case .responseTypeMismatch(let request):
            return "The registered stub has the wrong response type for \(request.requestTypeName)."
        }
    }
}

/// A deterministic, actor-isolated test double for ``APIClientProtocol``.
///
/// Exact request stubs take precedence over type-wide defaults. Request and
/// page operations have separate registries, and missing stubs always throw.
public actor MockAPIClient: APIClientProtocol {
    public typealias Sleeper = @Sendable (UInt64) async throws -> Void

    public private(set) var recordedRequests: [RecordedRequest] = []

    /// Path-only records retained for compatibility with simple assertions.
    public var calledRequests: [String] {
        recordedRequests.map { request in
            guard request.operation == .page, let page = request.page else {
                return request.path
            }
            return "\(request.path)?page=\(page)"
        }
    }

    private var stubs: [StubKey: Stub] = [:]
    private let baseURL: URL
    private let encoderFactory: APIClient.EncoderFactory
    private var delayNanoseconds: UInt64
    private let sleeper: Sleeper

    public init(
        baseURL: URL? = nil,
        encoderFactory: @escaping APIClient.EncoderFactory = { JSONEncoder() },
        delay: TimeInterval = 0,
        sleeper: @escaping Sleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.baseURL = baseURL ?? URL(string: "https://mock.invalid")!
        self.encoderFactory = encoderFactory
        delayNanoseconds = Self.nanoseconds(for: delay)
        self.sleeper = sleeper
    }

    // MARK: Successful stubs

    public func stub<R: Request>(
        _ requestType: R.Type,
        with response: R.ReturnType
    ) {
        stubs[.type(requestType, operation: .request)] = .success(response)
    }

    public func stub<R: Request>(
        _ request: R,
        with response: R.ReturnType
    ) throws {
        stubs[try exactKey(for: request, operation: .request)] = .success(response)
    }

    public func stubPage<R: PaginatedRequest>(
        _ requestType: R.Type,
        with response: PaginatedResponse<R.ReturnType>
    ) {
        stubs[.type(requestType, operation: .page)] = .success(response)
    }

    public func stubPage<R: PaginatedRequest>(
        _ request: R,
        with response: PaginatedResponse<R.ReturnType>
    ) throws {
        stubs[try exactKey(for: request, operation: .page)] = .success(response)
    }

    // MARK: Failure stubs

    public func stubError<R: Request>(
        _ requestType: R.Type,
        error: any Error
    ) {
        stubs[.type(requestType, operation: .request)] = .failure(error)
    }

    public func stubError<R: Request>(
        _ request: R,
        error: any Error
    ) throws {
        stubs[try exactKey(for: request, operation: .request)] = .failure(error)
    }

    public func stubPageError<R: PaginatedRequest>(
        _ requestType: R.Type,
        error: any Error
    ) {
        stubs[.type(requestType, operation: .page)] = .failure(error)
    }

    public func stubPageError<R: PaginatedRequest>(
        _ request: R,
        error: any Error
    ) throws {
        stubs[try exactKey(for: request, operation: .page)] = .failure(error)
    }

    // MARK: Compatibility aliases

    public func mock<R: Request>(
        _ requestType: R.Type,
        with response: R.ReturnType
    ) {
        stub(requestType, with: response)
    }

    public func mock<R: Request>(
        _ request: R,
        with response: R.ReturnType
    ) throws {
        try stub(request, with: response)
    }

    public func mock<R: PaginatedRequest>(
        _ requestType: R.Type,
        with response: PaginatedResponse<R.ReturnType>
    ) {
        stubPage(requestType, with: response)
    }

    public func mock<R: PaginatedRequest>(
        _ request: R,
        with response: PaginatedResponse<R.ReturnType>
    ) throws {
        try stubPage(request, with: response)
    }

    public func mockError<R: Request>(
        _ requestType: R.Type,
        with error: any Error
    ) {
        stubError(requestType, error: error)
    }

    public func mockError<R: Request>(
        _ request: R,
        with error: any Error
    ) throws {
        try stubError(request, error: error)
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

    public func resetMocks() {
        reset()
    }

    // MARK: APIClientProtocol

    public func send<R: Request>(_ request: R) async throws -> R.ReturnType {
        try Task.checkCancellation()
        let context = try makeContext(for: request, operation: .request)
        let invocation = record(request, operation: .request, context: context)
        let resolvedStub = resolve(
            R.self,
            operation: .request,
            signature: context.signature
        )
        let delay = delayNanoseconds

        try await wait(delay)

        guard let resolvedStub else {
            throw MockAPIClientError.missingStub(invocation)
        }

        switch resolvedStub {
        case .success(let value):
            guard let response = value as? R.ReturnType else {
                throw MockAPIClientError.responseTypeMismatch(invocation)
            }
            return response
        case .failure(let error):
            throw error
        }
    }

    public func sendPage<R: PaginatedRequest>(
        _ request: R
    ) async throws -> PaginatedResponse<R.ReturnType> {
        try Task.checkCancellation()
        let context = try makeContext(for: request, operation: .page)
        let invocation = record(request, operation: .page, context: context)
        let resolvedStub = resolve(
            R.self,
            operation: .page,
            signature: context.signature
        )
        let delay = delayNanoseconds

        try await wait(delay)

        guard let resolvedStub else {
            throw MockAPIClientError.missingStub(invocation)
        }

        switch resolvedStub {
        case .success(let value):
            guard let response = value as? PaginatedResponse<R.ReturnType> else {
                throw MockAPIClientError.responseTypeMismatch(invocation)
            }
            return response
        case .failure(let error):
            throw error
        }
    }

    private func wait(_ nanoseconds: UInt64) async throws {
        try Task.checkCancellation()
        if nanoseconds > 0 {
            try await sleeper(nanoseconds)
        }
        try Task.checkCancellation()
    }

    private func resolve<R: Request>(
        _ requestType: R.Type,
        operation: MockRequestOperation,
        signature: Signature
    ) -> Stub? {
        stubs[.exact(requestType, operation: operation, signature: signature)]
            ?? stubs[.type(requestType, operation: operation)]
    }

    private func exactKey<R: Request>(
        for request: R,
        operation: MockRequestOperation
    ) throws -> StubKey {
        let context = try makeContext(for: request, operation: operation)
        return .exact(R.self, operation: operation, signature: context.signature)
    }

    private func makeContext<R: Request>(
        for request: R,
        operation: MockRequestOperation
    ) throws -> RequestContext {
        guard let url = finalURL(for: request, operation: operation) else {
            throw NetworkError.invalidURL
        }

        let body: Data?
        do {
            body = try request.makeBody(using: encoderFactory())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NetworkError.encodingFailed(error)
        }

        return RequestContext(
            url: url,
            body: body,
            signature: Signature(request, url: url, body: body)
        )
    }

    private func finalURL<R: Request>(
        for request: R,
        operation: MockRequestOperation
    ) -> URL? {
        guard let requestURL = request.makeURL(baseURL: baseURL) else {
            return nil
        }
        guard operation == .page,
              let paginated = request as? any PaginatedRequest,
              var components = URLComponents(
                url: requestURL,
                resolvingAgainstBaseURL: false
              ) else {
            return requestURL
        }

        let paginationNames = [paginated.pageQueryName, paginated.pageSizeQueryName]
        var queryItems = (components.queryItems ?? []).filter { item in
            !paginationNames.contains {
                $0.caseInsensitiveCompare(item.name) == .orderedSame
            }
        }
        queryItems.append(URLQueryItem(
            name: paginated.pageQueryName,
            value: String(paginated.page)
        ))
        queryItems.append(URLQueryItem(
            name: paginated.pageSizeQueryName,
            value: String(paginated.pageSize)
        ))
        components.queryItems = queryItems
        return components.url
    }

    @discardableResult
    private func record<R: Request>(
        _ request: R,
        operation: MockRequestOperation,
        context: RequestContext
    ) -> RecordedRequest {
        let paginated = request as? any PaginatedRequest
        let invocation = RecordedRequest(
            sequenceID: recordedRequests.count,
            operation: operation,
            requestTypeID: ObjectIdentifier(R.self),
            requestTypeName: String(reflecting: R.self),
            method: request.method,
            url: context.url,
            path: request.path,
            queryItems: URLComponents(
                url: context.url,
                resolvingAgainstBaseURL: false
            )?.queryItems ?? [],
            headers: request.headers ?? [:],
            body: context.body,
            page: paginated?.page,
            pageSize: paginated?.pageSize
        )
        recordedRequests.append(invocation)
        return invocation
    }

    private static func nanoseconds(for delay: TimeInterval) -> UInt64 {
        guard delay.isFinite, delay > 0 else { return 0 }
        let scaled = delay * 1_000_000_000
        guard scaled < Double(UInt64.max) else { return UInt64.max }
        return UInt64(scaled.rounded(.towardZero))
    }
}

private extension MockAPIClient {
    enum Stub: Sendable {
        case success(any Sendable)
        case failure(any Error)
    }

    struct RequestContext: Sendable {
        let url: URL
        let body: Data?
        let signature: Signature
    }

    struct StubKey: Hashable, Sendable {
        let operation: MockRequestOperation
        let requestType: ObjectIdentifier
        let signature: Signature?

        static func type<R: Request>(
            _ requestType: R.Type,
            operation: MockRequestOperation
        ) -> Self {
            Self(
                operation: operation,
                requestType: ObjectIdentifier(requestType),
                signature: nil
            )
        }

        static func exact<R: Request>(
            _ requestType: R.Type,
            operation: MockRequestOperation,
            signature: Signature
        ) -> Self {
            Self(
                operation: operation,
                requestType: ObjectIdentifier(requestType),
                signature: signature
            )
        }
    }

    struct Signature: Hashable, Sendable {
        let method: HTTPMethod
        let url: String
        let headers: [KeyValue]
        let body: Data?
        let page: Int?
        let pageSize: Int?

        init<R: Request>(_ request: R, url: URL, body: Data?) {
            method = request.method
            self.url = url.absoluteString
            headers = (request.headers ?? [:])
                .map { KeyValue(key: $0.key.lowercased(), value: $0.value) }
                .sorted()
            self.body = body

            if let paginated = request as? any PaginatedRequest {
                page = paginated.page
                pageSize = paginated.pageSize
            } else {
                page = nil
                pageSize = nil
            }
        }
    }

    struct KeyValue: Hashable, Comparable, Sendable {
        let key: String
        let value: String?

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.key != rhs.key {
                return lhs.key < rhs.key
            }
            return (lhs.value ?? "") < (rhs.value ?? "")
        }
    }
}
