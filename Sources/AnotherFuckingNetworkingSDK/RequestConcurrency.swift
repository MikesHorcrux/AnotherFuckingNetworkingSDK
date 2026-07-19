import Foundation

/// Errors raised while configuring a request concurrency limiter.
public enum RequestConcurrencyLimiterError: LocalizedError, Equatable, Sendable {
    case invalidMaximumRequests(Int)
    case invalidMaximumQueuedRequests(Int)
    case queueFull(maximumQueuedRequests: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidMaximumRequests(let value):
            return "The maximum concurrent request count must be positive, not \(value)."
        case .invalidMaximumQueuedRequests(let value):
            return "The maximum queued request count must be positive, not \(value)."
        case .queueFull(let maximumQueuedRequests):
            return "The request concurrency queue is full at \(maximumQueuedRequests) waiting requests."
        }
    }
}

/// An actor-isolated, FIFO limiter for bounded concurrent request work.
///
/// Waiting callers are cancellation-aware and are removed from the queue
/// before a permit is granted. The limiter does not retry, reorder, or cancel
/// the operation supplied by the caller.
public actor RequestConcurrencyLimiter: Sendable {
    public static let defaultMaximumQueuedRequests = 128

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    public let maximumConcurrentRequests: Int
    public let maximumQueuedRequests: Int

    private var activeRequests = 0
    private var waiters: [Waiter] = []

    public init(
        maximumConcurrentRequests: Int,
        maximumQueuedRequests: Int = RequestConcurrencyLimiter.defaultMaximumQueuedRequests
    ) throws {
        guard maximumConcurrentRequests > 0 else {
            throw RequestConcurrencyLimiterError.invalidMaximumRequests(
                maximumConcurrentRequests
            )
        }
        guard maximumQueuedRequests > 0 else {
            throw RequestConcurrencyLimiterError.invalidMaximumQueuedRequests(
                maximumQueuedRequests
            )
        }
        self.maximumConcurrentRequests = maximumConcurrentRequests
        self.maximumQueuedRequests = maximumQueuedRequests
    }

    /// Runs one operation while holding a request permit.
    public func withPermit<Value: Sendable>(
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    /// The current number of operations holding permits.
    public var activeRequestCount: Int {
        activeRequests
    }

    /// The current number of callers waiting for permits.
    public var waitingRequestCount: Int {
        waiters.count
    }

    private func acquire() async throws {
        if activeRequests < maximumConcurrentRequests {
            activeRequests += 1
            return
        }

        guard waiters.count < maximumQueuedRequests else {
            throw RequestConcurrencyLimiterError.queueFull(
                maximumQueuedRequests: maximumQueuedRequests
            )
        }

        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(
                        id: waiterID,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func release() {
        guard activeRequests > 0 else { return }
        activeRequests -= 1
        grantNextWaiterIfAvailable()
    }

    private func grantNextWaiterIfAvailable() {
        guard activeRequests < maximumConcurrentRequests,
              !waiters.isEmpty else {
            return
        }
        let waiter = waiters.removeFirst()
        activeRequests += 1
        waiter.continuation.resume()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

/// A response-capable API client that bounds concurrent request work.
///
/// The permit covers the complete response operation, including retries and
/// response decoding. It intentionally does not conform to the streaming or
/// transfer protocols: those APIs return resources whose lifetime extends
/// beyond the call and need a stream/file-aware lease policy.
public struct ConcurrencyLimitedAPIClient<BaseClient: APIClientResponseProtocol>:
    APIClientResponseProtocol,
    Sendable
{
    public let client: BaseClient
    public let limiter: RequestConcurrencyLimiter

    public init(
        client: BaseClient,
        limiter: RequestConcurrencyLimiter
    ) {
        self.client = client
        self.limiter = limiter
    }

    public func send<R: Request>(_ request: R) async throws -> R.ReturnType {
        try await limiter.withPermit {
            try await client.send(request)
        }
    }

    public func sendResponse<R: Request>(
        _ request: R
    ) async throws -> HTTPResponse<R.ReturnType> {
        try await limiter.withPermit {
            try await client.sendResponse(request)
        }
    }

    public func sendPage<R: PaginatedRequest>(
        _ request: R
    ) async throws -> PaginatedResponse<R.ReturnType> {
        try await limiter.withPermit {
            try await client.sendPage(request)
        }
    }

    public func sendPageResponse<R: PaginatedRequest>(
        _ request: R
    ) async throws -> HTTPResponse<PaginatedResponse<R.ReturnType>> {
        try await limiter.withPermit {
            try await client.sendPageResponse(request)
        }
    }
}
