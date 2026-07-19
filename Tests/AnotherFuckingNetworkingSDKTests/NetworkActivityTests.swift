import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("Network activity monitoring")
struct NetworkActivityTests {
    @Test("Outcomes and active work produce privacy-safe snapshots")
    func outcomes() async throws {
        let monitor = NetworkActivityMonitor()
        let started = AsyncSignal()

        #expect(try await monitor.track(.request) { 42 } == 42)

        do {
            let _: Void = try await monitor.track(.upload) {
                throw ActivityFixtureError.failed
            }
            Issue.record("Expected the tracked operation to fail")
        } catch let error as ActivityFixtureError {
            #expect(error == .failed)
        }

        let cancelled = Task {
            try await monitor.track(.download) {
                await started.signal()
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        await started.wait()
        #expect(monitor.currentSnapshot.activeCount(for: .download) == 1)

        cancelled.cancel()
        do {
            try await cancelled.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }

        let snapshot = monitor.currentSnapshot
        #expect(snapshot.totalActiveCount == 0)
        #expect(snapshot.succeededCount == 1)
        #expect(snapshot.failedCount == 1)
        #expect(snapshot.cancelledCount == 1)
        #expect(snapshot.revision == 6)
    }

    @Test("Concurrent transitions stay ordered and newest-only")
    func concurrentSnapshotOrdering() async {
        let monitor = NetworkActivityMonitor()
        let operationCount = 500
        let stream = monitor.snapshots()
        let subscriberReady = AsyncSignal()
        let revisions = Task { () -> [UInt64] in
            var observed: [UInt64] = []
            for await snapshot in stream {
                observed.append(snapshot.revision)
                if observed.count == 1 {
                    await subscriberReady.signal()
                }
                if snapshot.succeededCount == UInt64(operationCount) {
                    return observed
                }
            }
            return observed
        }
        guard await subscriberReady.wait() else {
            revisions.cancel()
            _ = await revisions.value
            return
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<operationCount {
                group.addTask {
                    _ = try? await monitor.track(.request) { () }
                }
            }
        }

        let observed = await revisions.value
        let expectedFinalRevision = UInt64(operationCount * 2)
        #expect(observed.first == 0)
        #expect(observed.last == expectedFinalRevision)
        #expect(zip(observed, observed.dropFirst()).allSatisfy {
            $0.0 < $0.1
        })
        #expect(
            monitor.currentSnapshot.succeededCount == UInt64(operationCount)
        )
        #expect(monitor.currentSnapshot.totalActiveCount == 0)
    }

    @Test("Committed operations are not post-cancelled by monitoring")
    func committedOperationWinsLateCancellation() async throws {
        let monitor = NetworkActivityMonitor()

        let task = Task {
            try await monitor.trackCommitted(.download) {
                withUnsafeCurrentTask { $0?.cancel() }
                return 42
            }
        }

        #expect(try await task.value == 42)
        let snapshot = monitor.currentSnapshot
        #expect(snapshot.totalActiveCount == 0)
        #expect(snapshot.succeededCount == 1)
        #expect(snapshot.cancelledCount == 0)
        #expect(snapshot.revision == 2)
    }

    @Test("Monitoring preserves a committed operation failure")
    func committedOperationFailureWinsLateCancellation() async {
        let monitor = NetworkActivityMonitor()

        let task = Task {
            try await monitor.trackCommitted(.download) { () in
                withUnsafeCurrentTask { $0?.cancel() }
                throw ActivityFixtureError.failed
            }
        }

        do {
            try await task.value
            Issue.record("Expected the committed operation failure")
        } catch let error as ActivityFixtureError {
            #expect(error == .failed)
        } catch {
            Issue.record("Expected ActivityFixtureError, got \(error)")
        }
        let snapshot = monitor.currentSnapshot
        #expect(snapshot.totalActiveCount == 0)
        #expect(snapshot.failedCount == 1)
        #expect(snapshot.cancelledCount == 0)
        #expect(snapshot.revision == 2)
    }

    @Test("Cancelling iteration removes the subscriber")
    func subscriberTermination() async {
        let monitor = NetworkActivityMonitor()
        let stream = monitor.snapshots()
        #expect(monitor.subscriberCount == 1)

        let task = Task {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            _ = await iterator.next()
        }
        await Task.yield()
        task.cancel()
        await task.value

        for _ in 0..<1_000 where monitor.subscriberCount != 0 {
            await Task.yield()
        }
        #expect(monitor.subscriberCount == 0)
    }

    @Test("APIClient reports one logical request")
    func clientIntegration() async throws {
        let stub = StubSession { request in
            .respond(try .http(
                for: request,
                data: Data(#"{"id":42,"displayName":"Arthur"}"#.utf8)
            ))
        }
        let monitor = NetworkActivityMonitor()
        let client = stub.client(activityMonitor: monitor)

        _ = try await client.send(GetUserRequest(id: 42))

        let snapshot = monitor.currentSnapshot
        #expect(snapshot.activeCount(for: .request) == 0)
        #expect(snapshot.succeededCount == 1)
        #expect(snapshot.failedCount == 0)
        #expect(snapshot.revision == 2)
    }

    @available(iOS 17.0, macOS 14.0, *)
    @MainActor
    @Test("Observation adapter follows the bounded snapshot stream")
    func observationAdapter() async throws {
        let monitor = NetworkActivityMonitor()
        let observable = ObservableNetworkActivity(monitor: monitor)

        _ = try await monitor.track(.webSocketHandshake) { () }
        for _ in 0..<1_000 where observable.revision != 2 {
            await Task.yield()
        }

        #expect(observable.revision == 2)
        #expect(observable.totalActiveCount == 0)
        #expect(observable.succeededCount == 1)
        observable.stop()
    }
}

private enum ActivityFixtureError: Error, Equatable, Sendable {
    case failed
}
