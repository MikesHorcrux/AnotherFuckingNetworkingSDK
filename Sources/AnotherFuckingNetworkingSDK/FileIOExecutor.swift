import Dispatch

/// Runs blocking filesystem calls away from Swift's cooperative executor.
final class FileIOExecutor: Sendable {
    private struct WorkState: Sendable {
        var cancellationRequested = false
        var resultChosen = false
    }

    private struct CommittedWorkState: Sendable {
        var cancellationRequested = false
        var workStarted = false
    }

    static let shared = FileIOExecutor(
        queue: DispatchQueue(
            label: "com.mikeshorcrux.AnotherFuckingNetworkingSDK.file-io",
            qos: .utility,
            attributes: .concurrent,
            autoreleaseFrequency: .workItem
        )
    )

    private let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func run<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let workState = CriticalState(WorkState())

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    let shouldRun = workState.withCriticalRegion { state in
                        guard !state.cancellationRequested else {
                            state.resultChosen = true
                            return false
                        }
                        return true
                    }
                    guard shouldRun else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    let result: Result<Value, any Error> = Result {
                        try operation()
                    }
                    let cancellationWins = workState.withCriticalRegion { state in
                        state.resultChosen = true
                        return state.cancellationRequested
                    }
                    if cancellationWins {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(with: result)
                    }
                }
            }
        } onCancel: {
            workState.withCriticalRegion { state in
                guard !state.resultChosen else { return }
                state.cancellationRequested = true
            }
        }
    }

    /// Runs an irreversible filesystem mutation with a single commit point.
    ///
    /// Cancellation wins while the operation is still queued. Once the queue
    /// starts the mutation, its result wins so a successful move or replacement
    /// can never be reported as a cancellation with no recoverable file URL.
    func runCommitted<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let workState = CriticalState(CommittedWorkState())

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    let shouldRun = workState.withCriticalRegion { state in
                        guard !state.cancellationRequested else { return false }
                        state.workStarted = true
                        return true
                    }
                    guard shouldRun else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    continuation.resume(with: Result {
                        try operation()
                    })
                }
            }
        } onCancel: {
            workState.withCriticalRegion { state in
                guard !state.workStarted else { return }
                state.cancellationRequested = true
            }
        }
    }

    /// Runs best-effort resource cleanup even when the awaiting task is already
    /// cancelled. Cleanup remains off Swift's cooperative executor.
    func runCleanup(_ operation: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async {
                operation()
                continuation.resume()
            }
        }
    }
}
