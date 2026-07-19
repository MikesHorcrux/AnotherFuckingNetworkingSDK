import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK
@testable import AnotherFuckingNetworkingSDKTesting

@Suite("WebSocket reliability policies")
struct WebSocketReliabilityTests {
    @Test("Closed receives reconnect once and restore the session")
    func reconnectsReceive() async throws {
        let first = MockWebSocketConnection()
        await first.enqueueIncoming(error: WebSocketError.connectionClosed(nil))
        let second = MockWebSocketConnection(
            incoming: [.success(.text("restored"))]
        )
        let handshakes = LockedBox(0)
        let restored = LockedBox(0)
        let mock = MockWebSocketClient()
        await mock.stub(ReliabilitySocketRequest.self) { _ in
            let handshake = handshakes.withLock { value in
                value += 1
                return value
            }
            return handshake == 1 ? first : second
        }

        let client = WebSocketReliabilityClient(
            client: mock,
            policy: WebSocketReliabilityPolicy(
                maximumReconnectAttempts: 1,
                initialBackoffNanoseconds: 0,
                jitterRatio: 0
            ),
            sleeper: { _ in },
            random: { 0.5 },
            restorer: { _ in
                restored.withLock { $0 += 1 }
            }
        )
        let connection = try await client.connect(
            ReliabilitySocketRequest(value: "room")
        )

        #expect(try await connection.receive() == .text("restored"))
        #expect(handshakes.withLock { $0 } == 2)
        #expect(restored.withLock { $0 } == 1)
    }

    @Test("Send retries only after a transport close and preserves messages")
    func reconnectsSend() async throws {
        let first = MockWebSocketConnection()
        await first.enqueueSendResult(
            .failure(WebSocketError.connectionClosed(nil))
        )
        let second = MockWebSocketConnection()
        let handshakes = LockedBox(0)
        let mock = MockWebSocketClient()
        await mock.stub(ReliabilitySocketRequest.self) { _ in
            let handshake = handshakes.withLock { value in
                value += 1
                return value
            }
            return handshake == 1 ? first : second
        }

        let client = WebSocketReliabilityClient(
            client: mock,
            policy: WebSocketReliabilityPolicy(
                maximumReconnectAttempts: 1,
                initialBackoffNanoseconds: 0,
                jitterRatio: 0
            ),
            sleeper: { _ in },
            random: { 0.5 }
        )
        let connection = try await client.connect(
            ReliabilitySocketRequest(value: "room")
        )

        try await connection.send(.text("hello"))

        #expect(handshakes.withLock { $0 } == 2)
        #expect(await first.sentMessages == [.text("hello")])
        #expect(await second.sentMessages == [.text("hello")])
    }

    @Test("Heartbeat policy is bounded and rejects invalid values")
    func policyNormalization() {
        let policy = WebSocketReliabilityPolicy(
            maximumReconnectAttempts: -2,
            initialBackoffNanoseconds: 10,
            maximumBackoffNanoseconds: 1,
            backoffMultiplier: .nan,
            jitterRatio: 3,
            heartbeatIntervalNanoseconds: 0
        )

        #expect(policy.maximumReconnectAttempts == 0)
        #expect(policy.maximumBackoffNanoseconds == 10)
        #expect(policy.backoffMultiplier == 1)
        #expect(policy.jitterRatio == 1)
        #expect(policy.heartbeatIntervalNanoseconds == nil)
    }
}

private struct ReliabilitySocketRequest: WebSocketRequest {
    let value: String

    var path: String { "rooms/\(value)" }
}
