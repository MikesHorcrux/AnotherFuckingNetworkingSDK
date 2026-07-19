import Foundation

/// Limits for the opt-in in-memory response cache.
public struct ResponseCachePolicy: Equatable, Sendable {
    public let maximumEntries: Int
    public let maximumBytes: Int64
    /// `nil` keeps entries until eviction; `0` disables storage.
    public let timeToLive: TimeInterval?

    public static let disabled = Self(
        maximumEntries: 0,
        maximumBytes: 0,
        timeToLive: 0
    )

    public init(
        maximumEntries: Int = 128,
        maximumBytes: Int64 = 10 * 1_024 * 1_024,
        timeToLive: TimeInterval? = 300
    ) {
        self.maximumEntries = max(0, maximumEntries)
        self.maximumBytes = max(0, maximumBytes)
        self.timeToLive = timeToLive.map { max(0, $0) }
    }

    fileprivate var isEnabled: Bool {
        maximumEntries > 0 && maximumBytes > 0 && timeToLive != 0
    }
}

private struct ResponseCacheValidator: Equatable, Sendable {
    let headerName: String
    let value: String
}

private let maximumResponseCacheValidatorBytes = 1_024

private struct CachedResponse: @unchecked Sendable {
    let response: Any
    let byteCount: Int64
    var expiresAt: Date?
    let validator: ResponseCacheValidator?
    var lastAccess: UInt64
}

private actor ResponseCacheStorage {
    private var entries: [String: CachedResponse] = [:]
    private var totalBytes: Int64 = 0
    private var accessSequence: UInt64 = 0

    func value<Value: Sendable>(
        for key: String,
        as type: HTTPResponse<Value>.Type,
        now: Date
    ) -> HTTPResponse<Value>? {
        entry(for: key, as: type, now: now)?.response
    }

    func entry<Value: Sendable>(
        for key: String,
        as type: HTTPResponse<Value>.Type,
        now: Date,
        removeExpired: Bool = true
    ) -> (
        response: HTTPResponse<Value>,
        validator: ResponseCacheValidator?,
        isFresh: Bool
    )? {
        guard var entry = entries[key] else { return nil }
        let isExpired = entry.expiresAt.map { $0 <= now } ?? false
        if isExpired, removeExpired {
            remove(key)
            return nil
        }
        guard let response = entry.response as? HTTPResponse<Value> else {
            remove(key)
            return nil
        }
        accessSequence &+= 1
        entry.lastAccess = accessSequence
        entries[key] = entry
        return (response, entry.validator, !isExpired)
    }

    func insert<Value: Sendable>(
        _ response: HTTPResponse<Value>,
        for key: String,
        policy: ResponseCachePolicy,
        now: Date,
        validator: ResponseCacheValidator? = nil
    ) {
        guard policy.isEnabled else { return }
        let byteCount = max(1, Int64(response.data.count))
        guard byteCount <= policy.maximumBytes else {
            remove(key)
            return
        }

        remove(key)
        accessSequence &+= 1
        entries[key] = CachedResponse(
            response: response,
            byteCount: byteCount,
            expiresAt: policy.timeToLive.map {
                now.addingTimeInterval($0)
            },
            validator: validator,
            lastAccess: accessSequence
        )
        totalBytes += byteCount
        evict(to: policy)
    }

    func invalidate(_ key: String) {
        remove(key)
    }

    func refresh(
        _ key: String,
        policy: ResponseCachePolicy,
        now: Date
    ) {
        guard var entry = entries[key] else { return }
        entry.expiresAt = policy.timeToLive.map {
            now.addingTimeInterval($0)
        }
        accessSequence &+= 1
        entry.lastAccess = accessSequence
        entries[key] = entry
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: true)
        totalBytes = 0
    }

    private func evict(to policy: ResponseCachePolicy) {
        while entries.count > policy.maximumEntries || totalBytes > policy.maximumBytes {
            guard let key = entries.min(by: { lhs, rhs in
                lhs.value.lastAccess < rhs.value.lastAccess
            })?.key else { return }
            remove(key)
        }
    }

    private func remove(_ key: String) {
        if let entry = entries.removeValue(forKey: key) {
            totalBytes -= entry.byteCount
        }
    }
}

private struct ConditionalResponseNotModified: Error, Sendable {}

private struct ConditionalValidationRequest<Base: Request>: Request {
    typealias ReturnType = Base.ReturnType

    let base: Base
    let validator: ResponseCacheValidator

    var path: String { base.path }
    var pathEncoding: RequestPathEncoding { base.pathEncoding }
    var method: HTTPMethod { base.method }
    var queryItems: [URLQueryItem]? { base.queryItems }
    var body: Data? { base.body }
    var headers: [String: String]? { base.headers }
    var acceptedStatusCodes: HTTPStatusPolicy {
        base.acceptedStatusCodes.including(304)
    }
    var retryPolicy: HTTPRetryPolicy { base.retryPolicy }
    var maximumResponseBodyBytes: Int? { base.maximumResponseBodyBytes }
    var authenticationReplaySafety: HTTPRetryPolicy.ReplaySafety {
        base.authenticationReplaySafety
    }
    var allowsEmptyResponseBody: Bool { true }

    func makeURL(baseURL: URL) -> URL? {
        base.makeURL(baseURL: baseURL)
    }

    func makeBody(using encoder: JSONEncoder) throws -> Data? {
        try base.makeBody(using: encoder)
    }

    func customize(_ urlRequest: inout URLRequest) throws {
        try base.customize(&urlRequest)
        urlRequest.setValue(
            validator.value,
            forHTTPHeaderField: validator.headerName
        )
    }

    func decode(
        _ data: Data,
        response: HTTPURLResponse,
        using decoder: JSONDecoder
    ) throws -> Base.ReturnType {
        if response.statusCode == 304 {
            throw ConditionalResponseNotModified()
        }
        return try base.decode(data, response: response, using: decoder)
    }
}

/// A bounded response cache that revalidates stale entries with HTTP
/// validators before downloading the full response again.
///
/// Requests are keyed by the caller, just like ``CachedAPIClient``. A fresh
/// entry is returned without a network request. Once stale, the decorator
/// sends `If-None-Match` for an `ETag` validator or `If-Modified-Since` for a
/// `Last-Modified` validator. A `304 Not Modified` response returns the
/// previously decoded value and refreshes its TTL. Pagination methods are
/// forwarded unchanged; use ``sendResponse(_:)`` when caching a paginated
/// request explicitly.
public struct ConditionalCachedAPIClient<BaseClient: APIClientResponseProtocol>:
    APIClientResponseProtocol,
    Sendable {
    public typealias KeyProvider = @Sendable (any HTTPRequest) -> String?
    public typealias NowProvider = @Sendable () -> Date

    private let baseClient: BaseClient
    private let keyProvider: KeyProvider
    private let policy: ResponseCachePolicy
    private let now: NowProvider
    private let storage: ResponseCacheStorage

    public init(
        client: BaseClient,
        policy: ResponseCachePolicy = .init(),
        keyProvider: @escaping KeyProvider,
        now: @escaping NowProvider = { Date() }
    ) {
        baseClient = client
        self.policy = policy
        self.keyProvider = keyProvider
        self.now = now
        storage = ResponseCacheStorage()
    }

    public func invalidate(_ key: String) async {
        await storage.invalidate(key)
    }

    public func removeAllCachedResponses() async {
        await storage.removeAll()
    }

    public func send<R: Request>(_ request: R) async throws -> R.ReturnType {
        try await sendResponse(request).value
    }

    public func sendResponse<R: Request>(
        _ request: R
    ) async throws -> HTTPResponse<R.ReturnType> {
        try Task.checkCancellation()
        guard policy.isEnabled, let key = keyProvider(request) else {
            return try await baseClient.sendResponse(request)
        }

        if let cached = await storage.entry(
            for: key,
            as: HTTPResponse<R.ReturnType>.self,
            now: now(),
            removeExpired: false
        ) {
            if cached.isFresh {
                return cached.response
            }

            guard let validator = cached.validator else {
                let response = try await baseClient.sendResponse(request)
                await storage.insert(
                    response,
                    for: key,
                    policy: policy,
                    now: now(),
                    validator: Self.validator(from: response)
                )
                return response
            }

            let conditional = ConditionalValidationRequest(
                base: request,
                validator: validator
            )
            do {
                let response = try await baseClient.sendResponse(conditional)
                if response.statusCode == 304 {
                    await storage.refresh(key, policy: policy, now: now())
                    return cached.response
                }
                await storage.insert(
                    response,
                    for: key,
                    policy: policy,
                    now: now(),
                    validator: Self.validator(from: response)
                )
                return response
            } catch let error as NetworkError {
                guard case .decodingFailed(let underlying) = error,
                      underlying is ConditionalResponseNotModified else {
                    throw error
                }
                await storage.refresh(key, policy: policy, now: now())
                return cached.response
            }
        }

        let response = try await baseClient.sendResponse(request)
        await storage.insert(
            response,
            for: key,
            policy: policy,
            now: now(),
            validator: Self.validator(from: response)
        )
        return response
    }

    public func sendPage<R: PaginatedRequest>(
        _ request: R
    ) async throws -> PaginatedResponse<R.ReturnType> {
        try await baseClient.sendPage(request)
    }

    public func sendPageResponse<R: PaginatedRequest>(
        _ request: R
    ) async throws -> HTTPResponse<PaginatedResponse<R.ReturnType>> {
        try await baseClient.sendPageResponse(request)
    }

    private static func validator<Value: Sendable>(
        from response: HTTPResponse<Value>
    ) -> ResponseCacheValidator? {
        let candidates = [
            ("If-None-Match", response.value(forHTTPHeaderField: "ETag")),
            ("If-Modified-Since", response.value(forHTTPHeaderField: "Last-Modified"))
        ]
        for (headerName, value) in candidates {
            guard let value,
                  !value.isEmpty,
                  value.utf8.count <= maximumResponseCacheValidatorBytes else {
                continue
            }
            return ResponseCacheValidator(headerName: headerName, value: value)
        }
        return nil
    }
}

/// A typed API client decorator with explicit, bounded in-memory caching.
///
/// Only successful `HTTPResponse` values are cached. The cache is keyed by a
/// caller-provided string and does not infer authentication, locale, or
/// request-body identity. Mutations are never automatically invalidated;
/// callers should invalidate affected keys after a successful write.
public struct CachedAPIClient<BaseClient: APIClientResponseProtocol>:
    APIClientResponseProtocol,
    Sendable {
    public typealias KeyProvider = @Sendable (any HTTPRequest) -> String?
    public typealias NowProvider = @Sendable () -> Date

    private let baseClient: BaseClient
    private let keyProvider: KeyProvider
    private let policy: ResponseCachePolicy
    private let now: NowProvider
    private let storage: ResponseCacheStorage

    public init(
        client: BaseClient,
        policy: ResponseCachePolicy = .init(),
        keyProvider: @escaping KeyProvider,
        now: @escaping NowProvider = { Date() }
    ) {
        baseClient = client
        self.policy = policy
        self.keyProvider = keyProvider
        self.now = now
        storage = ResponseCacheStorage()
    }

    /// Removes one cache key. Call after a successful mutation.
    public func invalidate(_ key: String) async {
        await storage.invalidate(key)
    }

    /// Clears every cached response owned by this decorator.
    public func removeAllCachedResponses() async {
        await storage.removeAll()
    }

    public func send<R: Request>(_ request: R) async throws -> R.ReturnType {
        try await sendResponse(request).value
    }

    public func sendResponse<R: Request>(
        _ request: R
    ) async throws -> HTTPResponse<R.ReturnType> {
        try await execute(request) {
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
        try await execute(request) {
            try await baseClient.sendPageResponse(request)
        }
    }

    private func execute<R: HTTPRequest, Value: Sendable>(
        _ request: R,
        operation: @escaping @Sendable () async throws -> HTTPResponse<Value>
    ) async throws -> HTTPResponse<Value> {
        try Task.checkCancellation()
        guard policy.isEnabled, let key = keyProvider(request) else {
            return try await operation()
        }
        if let cached = await storage.value(
            for: key,
            as: HTTPResponse<Value>.self,
            now: now()
        ) {
            return cached
        }

        let response = try await operation()
        try Task.checkCancellation()
        await storage.insert(response, for: key, policy: policy, now: now())
        return response
    }
}
