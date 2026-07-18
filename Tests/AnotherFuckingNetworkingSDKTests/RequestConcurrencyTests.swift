import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK
@testable import AnotherFuckingNetworkingSDKTesting

@Suite("Request concurrency limiter")
struct RequestConcurrencyTests {
    @Test("The maximum request count must be positive")
    func invalidMaximum() {
        do {
            _ = try RequestConcurrencyLimiter(maximumConcurrentRequests: 0)
            Issue.record("Expected invalid maximum")
        } catch let error as RequestConcurrencyLimiterError {
            #expect(error == .invalidMaximumRequests(0))
        } catch {
            Issue.record("Expected limiter error, got \(error)")
        }
    }

    @Test("Permits are bounded and queued work resumes in FIFO order")
    func boundedFIFO() async throws {
        let limiter = try RequestConcurrencyLimiter(maximumConcurrentRequests: 1)
        let firstStarted = AsyncSignal()
        let releaseFirst = AsyncSignal()

        let first = Task {
            try await limiter.withPermit {
                await firstStarted.signal()
                _ = await releaseFirst.wait()
                return 1
            }
        }
        #expect(await firstStarted.wait())

        let second = Task {
            try await limiter.withPermit { 2 }
        }
        let third = Task {
            try await limiter.withPermit { 3 }
        }

        for _ in 0..<100 {
            if await limiter.waitingRequestCount == 2 { break }
            await Task.yield()
        }
        #expect(await limiter.activeRequestCount == 1)
        #expect(await limiter.waitingRequestCount == 2)

        await releaseFirst.signal()
        #expect(try await first.value == 1)
        #expect(try await second.value == 2)
        #expect(try await third.value == 3)
        #expect(await limiter.activeRequestCount == 0)
    }

    @Test("Cancelled waiters leave the queue and do not consume a permit")
    func cancellationRemovesWaiter() async throws {
        let limiter = try RequestConcurrencyLimiter(maximumConcurrentRequests: 1)
        let firstStarted = AsyncSignal()
        let releaseFirst = AsyncSignal()

        let first = Task {
            try await limiter.withPermit {
                await firstStarted.signal()
                _ = await releaseFirst.wait()
            }
        }
        #expect(await firstStarted.wait())

        let cancelled = Task {
            try await limiter.withPermit { () }
        }
        for _ in 0..<100 {
            if await limiter.waitingRequestCount == 1 { break }
            await Task.yield()
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("Expected waiter cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await limiter.waitingRequestCount == 0)

        await releaseFirst.signal()
        try await first.value
        #expect(await limiter.activeRequestCount == 0)
    }

    @Test("The response decorator forwards typed and metadata-aware calls")
    func responseDecorator() async throws {
        let mock = MockAPIClient()
        let expected = TestUser(id: 73, displayName: "Limiter")
        await mock.stub(GetUserRequest.self, with: expected)
        let limiter = try RequestConcurrencyLimiter(maximumConcurrentRequests: 2)
        let client = ConcurrencyLimitedAPIClient(
            client: mock,
            limiter: limiter
        )

        #expect(try await client.send(GetUserRequest(id: 73)) == expected)
        let response = try await client.sendResponse(GetUserRequest(id: 73))
        #expect(response.value == expected)
        #expect(await limiter.activeRequestCount == 0)
    }
}
