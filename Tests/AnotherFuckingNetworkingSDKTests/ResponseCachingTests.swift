import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK
@testable import AnotherFuckingNetworkingSDKTesting

@Suite("Response caching")
struct ResponseCachingTests {
    @Test("Successful responses are reused until their TTL expires")
    func cachesUntilExpiry() async throws {
        let mock = MockAPIClient()
        await mock.stubResponse(
            CacheRequest.self,
            with: HTTPResponse(
                value: CachedPayload(value: 42),
                data: Data(repeating: 1, count: 4),
                metadata: HTTPResponseMetadata(statusCode: 200)
            )
        )
        let clock = LockedBox(Date(timeIntervalSince1970: 100))
        let client = CachedAPIClient(
            client: mock,
            policy: .init(maximumEntries: 4, maximumBytes: 100, timeToLive: 10),
            keyProvider: { request in
                (request as? CacheRequest).map { "cache:\($0.id)" }
            },
            now: { clock.withLock { $0 } }
        )

        _ = try await client.send(CacheRequest(id: "user"))
        _ = try await client.send(CacheRequest(id: "user"))
        #expect(await mock.recordedRequests.count == 1)

        clock.withLock { $0 = Date(timeIntervalSince1970: 111) }
        _ = try await client.send(CacheRequest(id: "user"))
        #expect(await mock.recordedRequests.count == 2)
    }

    @Test("Least recently used entries are evicted at the entry bound")
    func evictsLeastRecentlyUsed() async throws {
        let mock = MockAPIClient()
        await mock.stub(CacheRequest.self, with: CachedPayload(value: 1))
        let client = CachedAPIClient(
            client: mock,
            policy: .init(maximumEntries: 1, maximumBytes: 100, timeToLive: nil),
            keyProvider: { request in
                (request as? CacheRequest).map { $0.id }
            }
        )

        _ = try await client.send(CacheRequest(id: "one"))
        _ = try await client.send(CacheRequest(id: "two"))
        _ = try await client.send(CacheRequest(id: "one"))
        #expect(await mock.recordedRequests.count == 3)
    }

    @Test("Disabled policy and nil keys never retain responses")
    func bypassesStorage() async throws {
        let mock = MockAPIClient()
        await mock.stub(CacheRequest.self, with: CachedPayload(value: 1))
        let disabled = CachedAPIClient(
            client: mock,
            policy: .disabled,
            keyProvider: { _ in "same" }
        )
        _ = try await disabled.send(CacheRequest(id: "one"))
        _ = try await disabled.send(CacheRequest(id: "one"))

        let uncached = CachedAPIClient(client: mock) { _ in nil }
        _ = try await uncached.send(CacheRequest(id: "two"))
        _ = try await uncached.send(CacheRequest(id: "two"))
        #expect(await mock.recordedRequests.count == 4)
    }
}

private struct CacheRequest: Request {
    typealias ReturnType = CachedPayload
    let id: String
    var path: String { "cache/\(id)" }
}

private struct CachedPayload: Codable, Equatable, Sendable {
    let value: Int
}
