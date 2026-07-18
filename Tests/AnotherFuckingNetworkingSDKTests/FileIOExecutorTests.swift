import Dispatch
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("File I/O concurrency")
struct FileIOExecutorTests {
    @Test("Cancelled queued work never starts")
    func queuedCancellation() async throws {
        let queue = DispatchQueue(label: "file-io-queued-cancellation")
        let executor = FileIOExecutor(queue: queue)
        let releaseBlocker = DispatchSemaphore(value: 0)
        let blockerStarted = LockedBox(false)
        let cancelledWorkRan = LockedBox(false)

        let blocker = Task {
            try await executor.run {
                blockerStarted.withLock { $0 = true }
                releaseBlocker.wait()
            }
        }
        await waitUntil { blockerStarted.withLock { $0 } }

        let cancelled = Task {
            try await executor.run {
                cancelledWorkRan.withLock { $0 = true }
            }
        }
        await Task.yield()
        cancelled.cancel()
        releaseBlocker.signal()

        try await blocker.value
        do {
            try await cancelled.value
            Issue.record("Expected queued work cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(cancelledWorkRan.withLock { $0 } == false)
    }

    @Test("Cancellation during blocking work wins at completion")
    func runningCancellation() async {
        let queue = DispatchQueue(label: "file-io-running-cancellation")
        let executor = FileIOExecutor(queue: queue)
        let releaseWork = DispatchSemaphore(value: 0)
        let workStarted = LockedBox(false)

        let task = Task {
            try await executor.run {
                workStarted.withLock { $0 = true }
                releaseWork.wait()
                return 42
            }
        }
        await waitUntil { workStarted.withLock { $0 } }

        task.cancel()
        releaseWork.signal()

        do {
            _ = try await task.value
            Issue.record("Expected running work cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("Filesystem errors remain inspectable")
    func errorPassthrough() async {
        let executor = FileIOExecutor(
            queue: DispatchQueue(label: "file-io-error")
        )

        do {
            let _: Void = try await executor.run {
                throw FileIOFixtureError.expected
            }
            Issue.record("Expected the queued error")
        } catch let error as FileIOFixtureError {
            #expect(error == .expected)
        } catch {
            Issue.record("Expected FileIOFixtureError, got \(error)")
        }
    }
}

private enum FileIOFixtureError: Error, Equatable, Sendable {
    case expected
}

private func waitUntil(
    _ condition: @Sendable () -> Bool
) async {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for queued file I/O")
}
