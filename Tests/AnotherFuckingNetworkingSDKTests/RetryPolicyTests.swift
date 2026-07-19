import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("HTTP retry policy")
struct RetryPolicyTests {
    @Test("Policy normalization is canonical, bounded, and Sendable")
    func normalization() {
        requireSendable(HTTPRetryPolicy.never)
        #expect(HTTPRetryPolicy.transient(maximumAttempts: 1) == .never)
        #expect(HTTPRetryPolicy.transient(maximumAttempts: Int.min) == .never)
        #expect(
            HTTPRetryPolicy.transient(maximumAttempts: Int.max)
                == HTTPRetryPolicy.transient(maximumAttempts: 100)
        )
        #expect(
            HTTPRetryPolicy.transient(
                initialDelay: -1,
                maximumDelay: .nan,
                multiplier: .infinity,
                jitter: .none
            )
                == HTTPRetryPolicy.transient(
                    initialDelay: 0,
                    maximumDelay: 0,
                    multiplier: 1,
                    jitter: .none
                )
        )
        #expect(
            HTTPRetryPolicy.transient(
                retryableStatusCodes: .none,
                retryableURLErrorCodes: []
            ) == .never
        )
    }

    @Test("Exponential backoff is bounded and full jitter is validated")
    func exponentialBackoffAndJitter() {
        let failure = HTTPRetryFailure.transport(URLError(.timedOut))
        let policy = HTTPRetryPolicy.transient(
            maximumAttempts: 5,
            initialDelay: 0.25,
            maximumDelay: 1,
            multiplier: 2,
            jitter: .none
        )

        #expect(delay(policy, attempt: 1, failure: failure) == 250_000_000)
        #expect(delay(policy, attempt: 2, failure: failure) == 500_000_000)
        #expect(delay(policy, attempt: 3, failure: failure) == 1_000_000_000)
        #expect(delay(policy, attempt: 4, failure: failure) == 1_000_000_000)
        #expect(delay(policy, attempt: 5, failure: failure) == nil)

        let jittered = HTTPRetryPolicy.transient(
            maximumAttempts: 2,
            initialDelay: .infinity,
            maximumDelay: .infinity,
            jitter: .full
        )
        #expect(
            delay(
                jittered,
                attempt: 1,
                failure: failure,
                random: 1
            ) == UInt64.max
        )
        #expect(
            delay(
                jittered,
                attempt: 1,
                failure: failure,
                random: -1
            ) == 0
        )
        #expect(
            delay(
                jittered,
                attempt: 1,
                failure: failure,
                random: .nan
            ) == 0
        )
    }

    @Test("Replay safety uses the final customized HTTP method")
    func replaySafety() {
        let failure = HTTPRetryFailure.transport(URLError(.timedOut))
        let safe = HTTPRetryPolicy.transient(
            maximumAttempts: 2,
            initialDelay: 0,
            jitter: .none
        )

        for method in ["GET", "HEAD", "PUT", "DELETE", "OPTIONS"] {
            #expect(delay(safe, method: method, failure: failure) == 0)
        }
        for method in ["POST", "PATCH", "MKCOL", "head", "put", ""] {
            #expect(delay(safe, method: method, failure: failure) == nil)
        }

        let explicit = HTTPRetryPolicy.transient(
            maximumAttempts: 2,
            initialDelay: 0,
            jitter: .none,
            replaySafety: .explicitlyReplayable
        )
        #expect(delay(explicit, method: "POST", failure: failure) == 0)
        #expect(delay(explicit, method: "MKCOL", failure: failure) == 0)
    }

    @Test("Retry-After delta seconds override backoff without jitter")
    func retryAfterDelta() {
        let policy = HTTPRetryPolicy.transient(
            maximumAttempts: 2,
            initialDelay: 0.25,
            maximumDelay: 10,
            jitter: .full
        )

        #expect(delay(
            policy,
            failure: responseFailure(retryAfter: "2"),
            random: 0
        ) == 2_000_000_000)
        #expect(delay(
            policy,
            failure: responseFailure(retryAfter: "11")
        ) == nil)
        #expect(delay(
            policy,
            failure: responseFailure(
                retryAfter: "184467440737095516160000"
            )
        ) == nil)
        let unboundedPolicy = HTTPRetryPolicy.transient(
            maximumAttempts: 2,
            maximumDelay: .infinity,
            jitter: .none
        )
        #expect(delay(
            unboundedPolicy,
            failure: responseFailure(
                retryAfter: "184467440737095516160000"
            )
        ) == nil)

        for malformed in ["+2", "2.0", "2, 3", "-1", "  "] {
            #expect(delay(
                policy,
                failure: responseFailure(retryAfter: malformed),
                random: 1
            ) == 250_000_000)
        }
    }

    @Test("Retry-After accepts every HTTP-date form and response clock skew")
    func retryAfterDates() {
        let policy = HTTPRetryPolicy.transient(
            maximumAttempts: 2,
            initialDelay: 0.25,
            maximumDelay: 10,
            jitter: .none
        )
        let responseDate = "Fri, 18 Jul 2025 12:00:00 GMT"
        let injectedNow = Date(timeIntervalSince1970: 0)
        let formats = [
            "Fri, 18 Jul 2025 12:00:02 GMT",
            "Friday, 18-Jul-25 12:00:02 GMT",
            "Fri Jul 18 12:00:02 2025"
        ]

        for retryAfter in formats {
            let failure = responseFailure(
                retryAfter: retryAfter,
                date: responseDate
            )
            #expect(delay(
                policy,
                failure: failure,
                now: injectedNow
            ) == 2_000_000_000)
        }

        #expect(delay(
            policy,
            failure: responseFailure(
                retryAfter: "Fri, 18 Jul 2025 11:59:59 GMT",
                date: responseDate
            ),
            now: injectedNow
        ) == 0)

        let rollingYearPolicy = HTTPRetryPolicy.transient(
            maximumAttempts: 2,
            initialDelay: 0.25,
            maximumDelay: .infinity,
            jitter: .none
        )
        #expect(delay(
            rollingYearPolicy,
            failure: responseFailure(
                retryAfter: "Thursday, 18-Jul-75 12:00:00 GMT",
                date: "Sat, 18 Jul 2026 12:00:00 GMT"
            ),
            now: injectedNow
        ) == 1_546_300_800_000_000_000)

        let boundaryDate = "Thu, 01 Jan 2026 00:00:00 GMT"
        #expect(delay(
            rollingYearPolicy,
            failure: responseFailure(
                retryAfter: "Wednesday, 01-Jan-76 00:00:00 GMT",
                date: boundaryDate
            ),
            now: injectedNow
        ) == 1_577_836_800_000_000_000)
        #expect(delay(
            rollingYearPolicy,
            failure: responseFailure(
                retryAfter: "Wednesday, 01-Jan-76 00:00:01 GMT",
                date: boundaryDate
            ),
            now: injectedNow
        ) == 0)
    }

    @Test("Only configured transient failures retry")
    func configuredFailures() {
        let policy = HTTPRetryPolicy.transient(
            maximumAttempts: 2,
            initialDelay: 0,
            jitter: .none,
            retryableStatusCodes: .codes([409]),
            retryableURLErrorCodes: [.cannotConnectToHost]
        )

        #expect(delay(
            policy,
            failure: .response(HTTPFailure(
                metadata: HTTPResponseMetadata(statusCode: 409)
            ))
        ) == 0)
        #expect(delay(
            policy,
            failure: .response(HTTPFailure(
                metadata: HTTPResponseMetadata(statusCode: 503)
            ))
        ) == nil)
        #expect(delay(
            policy,
            failure: .transport(URLError(.cannotConnectToHost))
        ) == 0)
        #expect(delay(
            policy,
            failure: .transport(URLError(.timedOut))
        ) == nil)
    }
}

private func delay(
    _ policy: HTTPRetryPolicy,
    attempt: Int = 1,
    method: String = "GET",
    failure: HTTPRetryFailure,
    now: Date = Date(timeIntervalSince1970: 1_752_840_000),
    random: Double = 1
) -> UInt64? {
    policy.retryDelayNanoseconds(
        afterAttempt: attempt,
        method: method,
        failure: failure,
        now: now,
        randomUnitValue: random
    )
}

private func responseFailure(
    retryAfter: String,
    date: String? = nil
) -> HTTPRetryFailure {
    var headers = ["Retry-After": retryAfter]
    headers["Date"] = date
    return .response(HTTPFailure(
        metadata: HTTPResponseMetadata(
            statusCode: 503,
            headers: headers
        )
    ))
}

private func requireSendable<Value: Sendable>(_ value: Value) {}
