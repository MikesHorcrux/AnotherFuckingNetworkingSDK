import Foundation
import Testing
import AnotherFuckingNetworkingSDKTesting
@testable import AnotherFuckingNetworkingSDK

@Suite("WebSocket recovery stores")
struct WebSocketRecoveryTests {
    @Test("In-memory state is bounded and keyed")
    func inMemoryState() async throws {
        let store = InMemoryWebSocketRecoveryStore()
        let state = try WebSocketRecoveryState(
            payload: Data("cursor-42".utf8),
            updatedAt: Date(timeIntervalSince1970: 42)
        )

        try await store.save(state, for: "room-42")
        #expect(try await store.load(for: "room-42") == state)
        #expect(try await store.load(for: "room-43") == nil)

        await #expect(
            throws: WebSocketRecoveryStoreError.invalidKey
        ) {
            try await store.remove(for: "")
        }
        #expect(
            throws: WebSocketRecoveryStoreError.payloadTooLarge(
                maximumBytes: WebSocketRecoveryState.maximumPayloadBytes,
                actualBytes: WebSocketRecoveryState.maximumPayloadBytes + 1
            )
        ) {
            _ = try WebSocketRecoveryState(
                payload: Data(
                    repeating: 1,
                    count: WebSocketRecoveryState.maximumPayloadBytes + 1
                )
            )
        }
    }

    @Test("JSON state survives a new store actor and removal")
    func jsonState() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("afn-websocket-recovery-(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let state = try WebSocketRecoveryState(
            payload: Data([1, 2, 3]),
            updatedAt: Date(timeIntervalSince1970: 7)
        )
        try await JSONWebSocketRecoveryStore(fileURL: url).save(
            state,
            for: "session"
        )

        let restored = try await JSONWebSocketRecoveryStore(
            fileURL: url
        ).load(for: "session")
        #expect(restored == state)

        try await JSONWebSocketRecoveryStore(fileURL: url).remove(
            for: "session"
        )
        #expect(try await JSONWebSocketRecoveryStore(fileURL: url)
            .load(for: "session") == nil)
    }

    @Test("Recovery adapter supplies state and reconnect context")
    func adapter() async throws {
        let store = InMemoryWebSocketRecoveryStore()
        try await store.save(
            WebSocketRecoveryState(payload: Data("cursor".utf8)),
            for: "room"
        )
        let adapter = try WebSocketRecoveryAdapter(
            store: store,
            key: "room"
        ) { connection, context, state in
            #expect(context.attempt == 2)
            #expect(context.previousSubprotocol == "chat.v1")
            let cursor = String(
                data: state?.payload ?? Data(),
                encoding: .utf8
            ) ?? "none"
            try await connection.send(.text("resume:" + cursor))
        }
        let connection = MockWebSocketConnection()

        try await adapter.restorerWithContext(
            connection,
            WebSocketReconnectContext(
                attempt: 2,
                previousURL: URL(string: "wss://example.com/socket")!,
                previousSubprotocol: "chat.v1"
            )
        )

        #expect(await connection.sentMessages == [.text("resume:cursor")])
    }

    @Test("Typed JSON recovery adapter round-trips bounded checkpoints")
    func typedAdapter() async throws {
        let store = InMemoryWebSocketRecoveryStore()
        let adapter = try JSONWebSocketRecoveryAdapter<Checkpoint>(
            store: store,
            key: "room"
        ) { connection, context, checkpoint in
            #expect(context.attempt == 1)
            try await connection.send(.text(
                "resume:" + (checkpoint?.cursor ?? "none")
            ))
        }

        try await adapter.save(Checkpoint(cursor: "cursor-7", version: 7))
        let connection = MockWebSocketConnection()
        try await adapter.restore(
            connection,
            context: WebSocketReconnectContext(
                attempt: 1,
                previousURL: URL(string: "wss://example.com/socket")!
            )
        )

        #expect(await connection.sentMessages == [.text("resume:cursor-7")])
        try await adapter.remove()
        let codec = JSONWebSocketRecoveryCodec<Checkpoint>()
        let state = try codec.encode(Checkpoint(cursor: "a", version: 1))
        #expect(try codec.decode(state) == Checkpoint(cursor: "a", version: 1))
    }
}

private struct Checkpoint: Codable, Equatable, Sendable {
    let cursor: String
    let version: Int
}
