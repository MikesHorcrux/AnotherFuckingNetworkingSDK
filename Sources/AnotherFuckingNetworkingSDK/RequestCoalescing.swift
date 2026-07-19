import Foundation

private struct CoalescedValue: @unchecked Sendable {
    let value: Any
}

private actor RequestCoalescingRegistry {
    private var inFlight: [String: Task<CoalescedValue, Error>] = [:]

    func value(
        for key: String,
        operation: @escaping @Sendable () async throws -> CoalescedValue
    ) async throws -> CoalescedValue {
        if let task = inFlight[key] {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        }

        let task = Task { try await operation() }
        inFlight[key] = task
        do {
            let value = try await task.value
            inFlight[key] = nil
            try Task.checkCancellation()
            return value
        } catch {
            inFlight[key] = nil
            throw error
        }
    }
}

/// A typed API client decorator that shares concurrent requests by caller key.
///
/// Coalescing is single-flight only: completed responses are not retained.
/// The key provider must include every input that can change the response,
/// including the request type, path, query, headers, body, and auth scope when
/// those values matter. A `nil` key bypasses coalescing for that request.
public struct RequestCoalescingAPIClient<BaseClient: APIClientResponseProtocol>:
    APIClientResponseProtocol,
    Sendable {
    public typealias KeyProvider = @Sendable (any HTTPRequest) -> String?

    private let baseClient: BaseClient
    private let keyProvider: KeyProvider
    private let registry: RequestCoalescingRegistry

    public init(
        client: BaseClient,
        keyProvider: @escaping KeyProvider
    ) {
        baseClient = client
        self.keyProvider = keyProvider
        registry = RequestCoalescingRegistry()
    }

    public func send<R: Request>(_ request: R) async throws -> R.ReturnType {
        try await sendResponse(request).value
    }

    public func sendResponse<R: Request>(
        _ request: R
    ) async throws -> HTTPResponse<R.ReturnType> {
        let key = keyProvider(request)
        return try await coalesced(key: key) {
            try await baseClient.sendResponse(request)
        }
    }

    public func sendPage<R: PaginatedRequest>(
        _ request: R
    ) async throws -> PaginatedResponse<R.ReturnType> {
        try await sendPageResponse(request).value
    }

    public func sendPageResponse<R: PaginatedRequest>(
        _ request: R
    ) async throws -> HTTPResponse<PaginatedResponse<R.ReturnType>> {
        let key = keyProvider(request)
        return try await coalesced(key: key) {
            try await baseClient.sendPageResponse(request)
        }
    }

    private func coalesced<Value: Sendable>(
        key: String?,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard let key else {
            return try await operation()
        }
        let boxed = try await registry.value(for: key) {
            CoalescedValue(value: try await operation())
        }
        guard let value = boxed.value as? Value else {
            throw NetworkError.unknown(
                RequestCoalescingTypeMismatch(expected: String(reflecting: Value.self))
            )
        }
        return value
    }
}

private struct RequestCoalescingTypeMismatch: LocalizedError, Sendable {
    let expected: String

    var errorDescription: String? {
        "The coalescing key was reused for an incompatible response type (expected \(expected))."
    }
}
