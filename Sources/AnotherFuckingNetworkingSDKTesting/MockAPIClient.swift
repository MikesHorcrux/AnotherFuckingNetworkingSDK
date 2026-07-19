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
    public let path: String
    public let queryItems: [URLQueryItem]
    public let headers: [String: String]
    public let body: Data?
    public let page: Int?
    public let pageSize: Int?

    public init(
        sequenceID: Int,
        operation: MockRequestOperation,
        requestTypeID: ObjectIdentifier,
        requestTypeName: String,
        method: HTTPMethod,
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
    private var delayNanoseconds: UInt64
    private let sleeper: Sleeper

    public init(
        delay: TimeInterval = 0,
        sleeper: @escaping Sleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
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
    ) {
        stubs[.exact(request, operation: .request)] = .success(response)
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
    ) {
        stubs[.exact(request, operation: .page)] = .success(response)
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
    ) {
        stubs[.exact(request, operation: .request)] = .failure(error)
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
    ) {
        stubs[.exact(request, operation: .page)] = .failure(error)
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
    ) {
        stub(request, with: response)
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
    ) {
        stubPage(request, with: response)
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
    ) {
        stubError(request, error: error)
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
        let invocation = record(request, operation: .request)
        let resolvedStub = resolve(request, operation: .request)
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
        let invocation = record(request, operation: .page)
        let resolvedStub = resolve(request, operation: .page)
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
        _ request: R,
        operation: MockRequestOperation
    ) -> Stub? {
        stubs[.exact(request, operation: operation)]
            ?? stubs[.type(R.self, operation: operation)]
    }

    @discardableResult
    private func record<R: Request>(
        _ request: R,
        operation: MockRequestOperation
    ) -> RecordedRequest {
        let paginated = request as? any PaginatedRequest
        let invocation = RecordedRequest(
            sequenceID: recordedRequests.count,
            operation: operation,
            requestTypeID: ObjectIdentifier(R.self),
            requestTypeName: String(reflecting: R.self),
            method: request.method,
            path: request.path,
            queryItems: request.queryItems ?? [],
            headers: request.headers ?? [:],
            body: request.body,
            page: paginated?.page,
            pageSize: paginated?.pageSize
        )
        recordedRequests.append(invocation)
        return invocation
    }

    private static func nanoseconds(for delay: TimeInterval) -> UInt64 {
        guard delay.isFinite, delay > 0 else { return 0 }
        let maximumSeconds = Double(UInt64.max) / 1_000_000_000
        return UInt64(min(delay, maximumSeconds) * 1_000_000_000)
    }
}

private extension MockAPIClient {
    enum Stub: Sendable {
        case success(any Sendable)
        case failure(any Error)
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
            _ request: R,
            operation: MockRequestOperation
        ) -> Self {
            Self(
                operation: operation,
                requestType: ObjectIdentifier(R.self),
                signature: Signature(request)
            )
        }
    }

    struct Signature: Hashable, Sendable {
        let method: HTTPMethod
        let path: String
        let queryItems: [KeyValue]
        let headers: [KeyValue]
        let body: Data?
        let page: Int?
        let pageSize: Int?

        init<R: Request>(_ request: R) {
            method = request.method
            path = request.path
            queryItems = (request.queryItems ?? [])
                .map { KeyValue(key: $0.name, value: $0.value) }
                .sorted()
            headers = (request.headers ?? [:])
                .map { KeyValue(key: $0.key.lowercased(), value: $0.value) }
                .sorted()
            body = request.body

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
