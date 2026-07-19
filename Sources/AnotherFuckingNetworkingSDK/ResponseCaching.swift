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

private struct CachedResponse: @unchecked Sendable {
    let response: Any
    let byteCount: Int64
    let expiresAt: Date?
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
        guard var entry = entries[key] else { return nil }
        if let expiresAt = entry.expiresAt, expiresAt <= now {
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
        return response
    }

    func insert<Value: Sendable>(
        _ response: HTTPResponse<Value>,
        for key: String,
        policy: ResponseCachePolicy,
        now: Date
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
            lastAccess: accessSequence
        )
        totalBytes += byteCount
        evict(to: policy)
    }

    func invalidate(_ key: String) {
        remove(key)
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
