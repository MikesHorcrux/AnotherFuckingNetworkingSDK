import Dispatch
import Foundation

/// Bounded failure and cooldown settings for an actor-isolated circuit.
public struct CircuitBreakerPolicy: Equatable, Sendable {
    public let failureThreshold: Int
    public let resetTimeoutNanoseconds: UInt64

    public init(
        failureThreshold: Int = 5,
        resetTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    ) {
        self.failureThreshold = Swift.max(1, failureThreshold)
        self.resetTimeoutNanoseconds = resetTimeoutNanoseconds
    }
}

/// Errors raised when a circuit refuses work or receives an invalid key.
public enum CircuitBreakerError: LocalizedError, Equatable, Sendable {
    case invalidKey
    case open(retryAfterNanoseconds: UInt64)

    public var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "The circuit-breaker key is empty or too long."
        case .open(let retryAfterNanoseconds):
            return "The circuit is open; retry after \(retryAfterNanoseconds) nanoseconds."
        }
    }
}

/// A privacy-safe circuit status suitable for diagnostics or Observation.
public enum CircuitBreakerStatus: Equatable, Sendable {
    case closed(failures: Int)
    case open(retryAfterNanoseconds: UInt64)
    case halfOpen
}

/// Actor-isolated failure suppression with one bounded half-open probe.
public actor CircuitBreaker {
    public typealias Clock = @Sendable () -> UInt64
    public typealias FailureClassifier = @Sendable (any Error) -> Bool

    private struct Entry: Sendable {
        var failures = 0
        var openedAt: UInt64?
        var halfOpenInFlight = false
    }

    private let policy: CircuitBreakerPolicy
    private let now: Clock
    private let failureClassifier: FailureClassifier
    private var entries: [String: Entry] = [:]

    public init(
        policy: CircuitBreakerPolicy = .init(),
        now: @escaping Clock = { DispatchTime.now().uptimeNanoseconds },
        failureClassifier: @escaping FailureClassifier = { _ in true }
    ) {
        self.policy = policy
        self.now = now
        self.failureClassifier = failureClassifier
    }

    /// Returns the current state without exposing error details or payloads.
    public func status(for key: String) throws -> CircuitBreakerStatus {
        try validateCircuitBreakerKey(key)
        guard let entry = entries[key] else { return .closed(failures: 0) }

        guard let openedAt = entry.openedAt else {
            return .closed(failures: entry.failures)
        }

        let elapsed = now() &- openedAt
        guard elapsed < policy.resetTimeoutNanoseconds else {
            return .halfOpen
        }
        return .open(
            retryAfterNanoseconds: policy.resetTimeoutNanoseconds - elapsed
        )
    }

    /// Runs one keyed operation when the circuit permits it.
    public func execute<Value: Sendable>(
        key: String?,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard let key else {
            return try await operation()
        }
        try validateCircuitBreakerKey(key)
        let halfOpenProbe = try begin(key: key)

        do {
            let value = try await operation()
            completeSuccess(key: key)
            return value
        } catch {
            if error is CancellationError {
                completeCancellation(key: key, halfOpenProbe: halfOpenProbe)
            } else if failureClassifier(error) {
                completeFailure(key: key, halfOpenProbe: halfOpenProbe)
            } else if halfOpenProbe {
                completeCancellation(key: key, halfOpenProbe: true)
            }
            throw error
        }
    }

    private func begin(key: String) throws -> Bool {
        var entry = entries[key] ?? Entry()
        guard let openedAt = entry.openedAt else {
            entries[key] = entry
            return false
        }

        let elapsed = now() &- openedAt
        guard elapsed >= policy.resetTimeoutNanoseconds else {
            throw CircuitBreakerError.open(
                retryAfterNanoseconds: policy.resetTimeoutNanoseconds - elapsed
            )
        }
        guard !entry.halfOpenInFlight else {
            throw CircuitBreakerError.open(retryAfterNanoseconds: 0)
        }
        entry.halfOpenInFlight = true
        entries[key] = entry
        return true
    }

    private func completeSuccess(key: String) {
        entries.removeValue(forKey: key)
    }

    private func completeCancellation(key: String, halfOpenProbe: Bool) {
        guard halfOpenProbe, var entry = entries[key] else { return }
        entry.halfOpenInFlight = false
        entries[key] = entry
    }

    private func completeFailure(key: String, halfOpenProbe: Bool) {
        var entry = entries[key] ?? Entry()
        if halfOpenProbe {
            entry.openedAt = now()
            entry.halfOpenInFlight = false
        } else {
            entry.failures = Swift.min(Int.max, entry.failures + 1)
            if entry.failures >= policy.failureThreshold {
                entry.openedAt = now()
            }
        }
        entries[key] = entry
    }
}

/// A response-capable client decorator that suppresses repeated keyed failures.
public struct CircuitBreakingAPIClient<BaseClient: APIClientResponseProtocol>:
    APIClientResponseProtocol,
    Sendable
{
    public typealias KeyProvider = @Sendable (any HTTPRequest) -> String?

    private let baseClient: BaseClient
    private let breaker: CircuitBreaker
    private let keyProvider: KeyProvider

    public init(
        client: BaseClient,
        breaker: CircuitBreaker,
        keyProvider: @escaping KeyProvider
    ) {
        baseClient = client
        self.breaker = breaker
        self.keyProvider = keyProvider
    }

    public func send<R: Request>(_ request: R) async throws -> R.ReturnType {
        try await sendResponse(request).value
    }

    public func sendResponse<R: Request>(
        _ request: R
    ) async throws -> HTTPResponse<R.ReturnType> {
        try await breaker.execute(key: keyProvider(request)) {
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
        try await breaker.execute(key: keyProvider(request)) {
            try await baseClient.sendPageResponse(request)
        }
    }
}

private func validateCircuitBreakerKey(_ key: String) throws {
    guard !key.isEmpty, key.utf8.count <= 256 else {
        throw CircuitBreakerError.invalidKey
    }
}
