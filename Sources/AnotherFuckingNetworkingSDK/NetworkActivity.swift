import Foundation

/// The kind of work represented by a network activity snapshot.
public enum NetworkOperationKind: String, CaseIterable, Hashable, Sendable {
    case request
    case upload
    case download
    case webSocketHandshake
}

/// A privacy-safe, immutable view of in-flight and completed network work.
///
/// Snapshots intentionally contain no URLs, headers, bodies, or errors. The
/// revision increases after every start and finish transition.
public struct NetworkActivitySnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let activeOperations: [NetworkOperationKind: Int]
    public let succeededCount: UInt64
    public let failedCount: UInt64
    public let cancelledCount: UInt64

    public init(
        revision: UInt64 = 0,
        activeOperations: [NetworkOperationKind: Int] = [:],
        succeededCount: UInt64 = 0,
        failedCount: UInt64 = 0,
        cancelledCount: UInt64 = 0
    ) {
        self.revision = revision
        self.activeOperations = activeOperations.filter { $0.value > 0 }
        self.succeededCount = succeededCount
        self.failedCount = failedCount
        self.cancelledCount = cancelledCount
    }

    public var totalActiveCount: Int {
        activeOperations.values.reduce(0, +)
    }

    public func activeCount(for kind: NetworkOperationKind) -> Int {
        activeOperations[kind, default: 0]
    }
}

/// Opt-in activity monitoring for concurrent networking work.
///
/// The monitor uses a short synchronous critical region so reporting does not
/// add actor hops to request hot paths. Consumers receive bounded, coalescing
/// snapshots: a slow consumer retains only the newest state. The ordinary
/// client path performs no monitoring work when no monitor is injected.
public final class NetworkActivityMonitor: Sendable {
    private typealias Continuation = AsyncStream<
        NetworkActivitySnapshot
    >.Continuation

    private struct OperationToken: Sendable {
        let id: UInt64
        let kind: NetworkOperationKind
    }

    private struct State: Sendable {
        var revision: UInt64 = 0
        var nextOperationID: UInt64 = 0
        var activeOperations: [UInt64: NetworkOperationKind] = [:]
        var activeCounts: [NetworkOperationKind: Int] = [:]
        var succeededCount: UInt64 = 0
        var failedCount: UInt64 = 0
        var cancelledCount: UInt64 = 0
        var subscribers: [UUID: Continuation] = [:]

        var snapshot: NetworkActivitySnapshot {
            NetworkActivitySnapshot(
                revision: revision,
                activeOperations: activeCounts,
                succeededCount: succeededCount,
                failedCount: failedCount,
                cancelledCount: cancelledCount
            )
        }

        mutating func publish() {
            revision &+= 1
            let snapshot = snapshot
            var terminatedSubscribers: [UUID] = []

            // Yielding while serialized preserves revision order when several
            // request tasks finish concurrently. AsyncStream yield is
            // synchronous and never waits for a consumer.
            for (id, continuation) in subscribers {
                switch continuation.yield(snapshot) {
                case .enqueued, .dropped:
                    break
                case .terminated:
                    terminatedSubscribers.append(id)
                @unknown default:
                    break
                }
            }

            for id in terminatedSubscribers {
                subscribers[id] = nil
            }
        }
    }

    private enum Outcome {
        case succeeded
        case failed
        case cancelled
    }

    private let state = CriticalState(State())

    public init() {}

    /// The latest snapshot without creating a subscription.
    public var currentSnapshot: NetworkActivitySnapshot {
        state.withCriticalRegion { $0.snapshot }
    }

    /// Creates an independent newest-only stream beginning with the current
    /// snapshot. Cancelling a task waiting on the stream removes its subscriber.
    public func snapshots() -> AsyncStream<NetworkActivitySnapshot> {
        let id = UUID()

        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            continuation.onTermination = { [weak self] _ in
                // Termination can be reported by yield itself, so cleanup must
                // not re-enter the critical region synchronously.
                Task { self?.removeSubscriber(id) }
            }

            let terminated = state.withCriticalRegion { state in
                state.subscribers[id] = continuation
                if case .terminated = continuation.yield(state.snapshot) {
                    return true
                }
                return false
            }
            if terminated {
                removeSubscriber(id)
            }
        }
    }

    /// Tracks one operation and preserves cancellation as `CancellationError`.
    public func track<Value: Sendable>(
        _ kind: NetworkOperationKind,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await track(
            kind,
            cancellationWinsAfterOperation: true,
            operation: operation
        )
    }

    /// Tracks an operation whose successful return follows an irreversible
    /// commit point. The operation remains responsible for cancellation before
    /// that point; a late cancellation cannot turn committed success into a
    /// failure that hides the resulting resource.
    func trackCommitted<Value: Sendable>(
        _ kind: NetworkOperationKind,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try await track(
            kind,
            cancellationWinsAfterOperation: false,
            operation: operation
        )
    }

    private func track<Value: Sendable>(
        _ kind: NetworkOperationKind,
        cancellationWinsAfterOperation: Bool,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let token = begin(kind)

        do {
            let value = try await operation()
            if cancellationWinsAfterOperation {
                try Task.checkCancellation()
            }
            finish(token, outcome: .succeeded)
            return value
        } catch {
            let cancellationWon = error is CancellationError
                || (cancellationWinsAfterOperation && Task.isCancelled)
            if cancellationWon {
                finish(token, outcome: .cancelled)
                throw CancellationError()
            }
            finish(token, outcome: .failed)
            throw error
        }
    }

    var subscriberCount: Int {
        state.withCriticalRegion { $0.subscribers.count }
    }

    private func begin(_ kind: NetworkOperationKind) -> OperationToken {
        state.withCriticalRegion { state in
            let id = state.nextOperationID
            state.nextOperationID &+= 1
            state.activeOperations[id] = kind
            state.activeCounts[kind, default: 0] += 1
            state.publish()
            return OperationToken(id: id, kind: kind)
        }
    }

    private func finish(_ token: OperationToken, outcome: Outcome) {
        state.withCriticalRegion { state in
            guard state.activeOperations.removeValue(forKey: token.id) != nil else {
                return
            }

            let remaining = state.activeCounts[token.kind, default: 1] - 1
            state.activeCounts[token.kind] = remaining > 0 ? remaining : nil

            switch outcome {
            case .succeeded:
                state.succeededCount &+= 1
            case .failed:
                state.failedCount &+= 1
            case .cancelled:
                state.cancelledCount &+= 1
            }
            state.publish()
        }
    }

    private func removeSubscriber(_ id: UUID) {
        state.withCriticalRegion { state in
            state.subscribers[id] = nil
        }
    }
}
