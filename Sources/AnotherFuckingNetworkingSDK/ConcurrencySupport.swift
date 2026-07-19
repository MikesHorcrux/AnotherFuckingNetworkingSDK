import Foundation

/// A small synchronous critical region for callback-facing state.
///
/// `NSLock` remains the deployment-compatible primitive for the package's
/// iOS 15 and macOS 12 floor. The unchecked conformance is confined here: the
/// value is accessible only while the lock is held, the closure never escapes,
/// and no lock is held across an `await`.
final class CriticalState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func withCriticalRegion<Result>(
        _ operation: (inout Value) throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation(&value)
    }
}

/// A newest-only, ordered state broadcaster shared by the core and testing
/// products. Yielding occurs inside the short critical region so concurrent
/// publishers cannot deliver revisions out of order.
package final class LatestValueBroadcaster<Value: Equatable & Sendable>: Sendable {
    private typealias Continuation = AsyncStream<Value>.Continuation

    private struct State: Sendable {
        var value: Value
        var isFinished = false
        var subscribers: [UUID: Continuation] = [:]
    }

    private let state: CriticalState<State>

    package init(_ initialValue: Value) {
        state = CriticalState(State(value: initialValue))
    }

    package func stream() -> AsyncStream<Value> {
        let id = UUID()

        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }

            continuation.onTermination = { [weak self] _ in
                Task { self?.removeSubscriber(id) }
            }

            let shouldRemove = state.withCriticalRegion { state in
                if !state.isFinished {
                    state.subscribers[id] = continuation
                }
                let terminated: Bool
                if case .terminated = continuation.yield(state.value) {
                    terminated = true
                } else {
                    terminated = false
                }
                if state.isFinished {
                    continuation.finish()
                }
                return terminated || state.isFinished
            }
            if shouldRemove {
                removeSubscriber(id)
            }
        }
    }

    package func publish(_ value: Value) {
        state.withCriticalRegion { state in
            guard !state.isFinished, state.value != value else { return }
            state.value = value
            Self.yield(value, to: &state.subscribers)
        }
    }

    package func finish(with value: Value) {
        state.withCriticalRegion { state in
            guard !state.isFinished else {
                state.value = value
                return
            }
            state.value = value
            state.isFinished = true
            Self.yield(value, to: &state.subscribers)
            for continuation in state.subscribers.values {
                continuation.finish()
            }
            state.subscribers.removeAll(keepingCapacity: false)
        }
    }

    package func reset(to value: Value) {
        state.withCriticalRegion { state in
            let changed = state.value != value || state.isFinished
            state.value = value
            state.isFinished = false
            if changed {
                Self.yield(value, to: &state.subscribers)
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        state.withCriticalRegion { state in
            state.subscribers[id] = nil
        }
    }

    private static func yield(
        _ value: Value,
        to subscribers: inout [UUID: Continuation]
    ) {
        var terminated: [UUID] = []
        for (id, continuation) in subscribers {
            switch continuation.yield(value) {
            case .enqueued, .dropped:
                break
            case .terminated:
                terminated.append(id)
            @unknown default:
                break
            }
        }
        for id in terminated {
            subscribers[id] = nil
        }
    }
}
