import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK
@testable import AnotherFuckingNetworkingSDKTesting

@Suite("Request coalescing")
struct RequestCoalescingTests {
    @Test("Concurrent requests with one key share one underlying operation")
    func sharesConcurrentRequest() async throws {
        let mock = MockAPIClient(delay: 0.05)
        await mock.stub(CoalescedRequest.self, with: CoalescedPayload(value: 42))
        let client = RequestCoalescingAPIClient(client: mock) { request in
            guard let request = request as? CoalescedRequest else { return nil }
            return "\(String(reflecting: CoalescedRequest.self)):\(request.id)"
        }

        let values = try await withThrowingTaskGroup(of: CoalescedPayload.self) {
            group in
            for _ in 0..<8 {
                group.addTask {
                    try await client.send(CoalescedRequest(id: "profile"))
                }
            }
            return try await group.reduce(into: []) { values, value in
                values.append(value)
            }
        }

        #expect(values == Array(repeating: CoalescedPayload(value: 42), count: 8))
        #expect(await mock.recordedRequests.count == 1)
    }

    @Test("A nil key bypasses coalescing")
    func nilKeyDoesNotShare() async throws {
        let mock = MockAPIClient()
        await mock.stub(CoalescedRequest.self, with: CoalescedPayload(value: 7))
        let client = RequestCoalescingAPIClient(client: mock) { _ in nil }

        _ = try await client.send(CoalescedRequest(id: "one"))
        _ = try await client.send(CoalescedRequest(id: "two"))

        #expect(await mock.recordedRequests.count == 2)
    }
}

private struct CoalescedRequest: Request {
    typealias ReturnType = CoalescedPayload

    let id: String
    var path: String { "profiles/\(id)" }
}

private struct CoalescedPayload: Codable, Equatable, Sendable {
    let value: Int
}
