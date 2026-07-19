import Foundation
import Testing
import AnotherFuckingNetworkingSDKTesting
@testable import AnotherFuckingNetworkingSDK

@Suite("Circuit breaker")
struct CircuitBreakerTests {
    @Test("Repeated failures open, cool down, and close after a probe")
    func opensAndRecovers() async throws {
        let clock = CriticalState<UInt64>(0)
        let breaker = CircuitBreaker(
            policy: CircuitBreakerPolicy(
                failureThreshold: 2,
                resetTimeoutNanoseconds: 1_000
            ),
            now: { clock.withCriticalRegion { $0 } }
        )
        let failure = NSError(domain: "server", code: 503)

        for _ in 0..<2 {
            await #expect(throws: failure) {
                try await breaker.execute(key: "api") {
                    throw failure
                }
            }
        }
        #expect(try await breaker.status(for: "api") ==
            .open(retryAfterNanoseconds: 1_000))
        await #expect(throws: CircuitBreakerError.open(
            retryAfterNanoseconds: 1_000
        )) {
            try await breaker.execute(key: "api") { 42 }
        }

        clock.withCriticalRegion { $0 = 1_000 }
        #expect(try await breaker.status(for: "api") == .halfOpen)
        #expect(try await breaker.execute(key: "api") { 42 } == 42)
        #expect(try await breaker.status(for: "api") == .closed(failures: 0))
    }

    @Test("Cancellation and classified errors do not trip the circuit")
    func cancellationAndClassification() async throws {
        let breaker = CircuitBreaker(
            policy: CircuitBreakerPolicy(failureThreshold: 1),
            failureClassifier: { error in !(error is NonTripError) }
        )

        await #expect(throws: NonTripError()) {
            try await breaker.execute(key: "api") {
                throw NonTripError()
            }
        }
        #expect(try await breaker.status(for: "api") == .closed(failures: 0))

        do {
            _ = try await breaker.execute(key: "api") {
                throw CancellationError()
            }
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Cancellation is caller intent and must not trip the circuit.
        }
        #expect(try await breaker.status(for: "api") == .closed(failures: 0))
    }

    @Test("Keys are bounded and nil bypasses the circuit")
    func keyValidation() async throws {
        let breaker = CircuitBreaker()
        #expect(try await breaker.execute(key: nil) { "ok" } == "ok")
        await #expect(throws: CircuitBreakerError.invalidKey) {
            try await breaker.execute(key: "") { "never" }
        }
        await #expect(throws: CircuitBreakerError.invalidKey) {
            try await breaker.status(for: String(repeating: "x", count: 257))
        }
    }

    @Test("Response client decorator shares keyed circuit state")
    func responseDecorator() async throws {
        let base = MockAPIClient()
        await base.stubError(
            GetUserRequest.self,
            error: NSError(domain: "server", code: 500)
        )
        let breaker = CircuitBreaker(
            policy: CircuitBreakerPolicy(failureThreshold: 1),
            now: { 0 }
        )
        let client = CircuitBreakingAPIClient(
            client: base,
            breaker: breaker,
            keyProvider: { $0.path }
        )

        do {
            _ = try await client.send(GetUserRequest(id: 1))
            Issue.record("Expected the first request to fail")
        } catch {
            // The base error is deliberately preserved for callers.
        }
        await #expect(throws: CircuitBreakerError.open(
            retryAfterNanoseconds: 30 * 1_000_000_000
        )) {
            _ = try await client.send(GetUserRequest(id: 1))
        }
        #expect(await base.recordedRequests.count == 1)
    }
}

private struct NonTripError: Error, Equatable, Sendable {}
