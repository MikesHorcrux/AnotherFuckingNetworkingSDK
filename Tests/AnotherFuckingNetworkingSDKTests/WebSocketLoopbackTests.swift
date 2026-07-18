import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("WebSocket loopback integration", .serialized)
struct WebSocketLoopbackTests {
    @Test("Real URLSession tasks negotiate and exchange every frame type")
    func fullDuplexLifecycle() async throws {
        let serverBinary = Data((0..<130).map { UInt8($0) })
        let clientBinary = Data((0..<140).map { UInt8($0 & 0xff) })
        let server = try await LoopbackWebSocketServer.start(
            behavior: .accept(
                subprotocol: "chat.v2",
                initialMessages: [
                    .text("welcome"),
                    .binary(serverBinary),
                ]
            )
        )
        defer { server.stop() }

        let delegate = RecordingWebSocketSessionDelegate()
        let session = Self.makeSession(delegate: delegate)
        defer { session.invalidateAndCancel() }
        let client = APIClient(
            baseURL: try server.baseURL,
            urlSession: session,
            globalHeaders: ["X-Global": "global-value"]
        )
        let connection = try await withLoopbackTimeout {
            try await client.connect(LoopbackSocketRequest(
                path: "rooms/live socket",
                queryItems: [URLQueryItem(name: "room", value: "42")],
                headers: ["X-Request": "request-value"],
                subprotocols: ["chat.v2", "chat.v1"]
            ))
        }
        let lifecycleStarted = AsyncSignal()
        let lifecycleTask = Task {
            var states: [WebSocketConnectionState] = []
            for await state in connection.states {
                states.append(state)
                if states.count == 1 {
                    await lifecycleStarted.signal()
                }
            }
            return states
        }
        defer { lifecycleTask.cancel() }
        await lifecycleStarted.wait()

        #expect(await connection.state == .open)
        #expect(connection.negotiatedSubprotocol == "chat.v2")
        #expect(connection.url.scheme == "ws")
        #expect(try await withLoopbackTimeout {
            try await connection.receive()
        } == .text("welcome"))
        #expect(try await withLoopbackTimeout {
            try await connection.receive()
        } == .binary(serverBinary))

        try await withLoopbackTimeout {
            try await connection.send(text: "from-client")
        }
        try await withLoopbackTimeout {
            try await connection.send(data: clientBinary)
        }
        try await withLoopbackTimeout {
            try await connection.ping()
        }
        try await connection.close(code: .normalClosure, reason: "Done")

        let close = WebSocketClose(
            code: .normalClosure,
            reason: Data("Done".utf8)
        )
        let lifecycle = try await withLoopbackTimeout {
            await withTaskCancellationHandler {
                await lifecycleTask.value
            } onCancel: {
                lifecycleTask.cancel()
            }
        }
        #expect(lifecycle.first == .open)
        #expect(lifecycle.last == .closed(close))
        #expect(await connection.state == .closed(close))

        await server.waitForCompletion()
        await delegate.completionSignal.wait()

        let serverSnapshot = server.snapshot
        #expect(serverSnapshot.requestTarget
            == "/rooms/live%20socket?room=42")
        #expect(serverSnapshot.requestHeaders["x-global"] == "global-value")
        #expect(serverSnapshot.requestHeaders["x-request"] == "request-value")
        #expect(serverSnapshot.requestHeaders["sec-websocket-protocol"]
            == "chat.v2, chat.v1")
        #expect(serverSnapshot.receivedMessages == [
            .text("from-client"),
            .binary(clientBinary),
        ])
        #expect(serverSnapshot.pingCount == 1)
        #expect(serverSnapshot.receivedClose == close)
        #expect(serverSnapshot.failureDescription == nil)

        let delegateSnapshot = delegate.snapshot
        #expect(delegateSnapshot.openedSubprotocols == ["chat.v2"])
        #expect(delegateSnapshot.closes == [close])
        #expect(delegateSnapshot.completionCount == 1)
        #expect(delegateSnapshot.completionErrorDescriptions == [nil])
        delegateSnapshot.expectOneTaskAcrossEveryCallback()
    }

    @Test("A peer close wins the receive race without losing close details")
    func peerCloseDuringReceive() async throws {
        let server = try await LoopbackWebSocketServer.start(
            behavior: .accept()
        )
        defer { server.stop() }
        let delegate = RecordingWebSocketSessionDelegate()
        let session = Self.makeSession(delegate: delegate)
        defer { session.invalidateAndCancel() }
        let client = APIClient(
            baseURL: try server.baseURL,
            urlSession: session
        )
        let connection = try await withLoopbackTimeout {
            try await client.connect(LoopbackSocketRequest())
        }
        let lifecycleStarted = AsyncSignal()
        let lifecycleTask = Task {
            var states: [WebSocketConnectionState] = []
            for await state in connection.states {
                states.append(state)
                if states.count == 1 {
                    await lifecycleStarted.signal()
                }
            }
            return states
        }
        defer { lifecycleTask.cancel() }
        await lifecycleStarted.wait()

        let receiveTask = Task {
            try await connection.receive()
        }
        defer { receiveTask.cancel() }
        await Task.yield()
        try await connection.send(text: "receive-ready")
        await server.waitForMessage()
        #expect(server.snapshot.receivedMessages == [.text("receive-ready")])

        let close = WebSocketClose(
            code: .goingAway,
            reason: Data("Server maintenance".utf8)
        )
        try await server.closePeer(
            code: close.code,
            reason: "Server maintenance"
        )

        do {
            _ = try await withLoopbackTimeout {
                try await withTaskCancellationHandler {
                    try await receiveTask.value
                } onCancel: {
                    receiveTask.cancel()
                }
            }
            Issue.record("Expected the pending receive to observe peer closure")
        } catch let error as WebSocketError {
            guard case .connectionClosed(let receivedClose) = error else {
                Issue.record("Expected connectionClosed, got \(error)")
                return
            }
            #expect(receivedClose == close)
        }

        let lifecycle = try await withLoopbackTimeout {
            await withTaskCancellationHandler {
                await lifecycleTask.value
            } onCancel: {
                lifecycleTask.cancel()
            }
        }
        #expect(lifecycle.first == .open)
        #expect(lifecycle.last == .closed(close))
        #expect(await connection.state == .closed(close))

        await server.waitForCompletion()
        await delegate.completionSignal.wait()
        #expect(server.snapshot.receivedClose == close)
        #expect(server.snapshot.failureDescription == nil)

        let delegateSnapshot = delegate.snapshot
        #expect(delegateSnapshot.openedSubprotocols == [nil])
        #expect(delegateSnapshot.closes == [close])
        #expect(delegateSnapshot.completionErrorDescriptions == [nil])
        delegateSnapshot.expectOneTaskAcrossEveryCallback()
    }

    @Test("A real rejected upgrade preserves response metadata")
    func rejectedUpgradeMetadata() async throws {
        let server = try await LoopbackWebSocketServer.start(
            behavior: .reject(
                statusCode: 401,
                headers: [
                    "WWW-Authenticate": "Bearer realm=loopback",
                    "X-Rejection": "test-fixture",
                ]
            )
        )
        defer { server.stop() }
        let delegate = RecordingWebSocketSessionDelegate()
        let session = Self.makeSession(delegate: delegate)
        defer { session.invalidateAndCancel() }
        let client = APIClient(
            baseURL: try server.baseURL,
            urlSession: session
        )

        do {
            _ = try await withLoopbackTimeout {
                try await client.connect(LoopbackSocketRequest(
                    path: "private/socket"
                ))
            }
            Issue.record("Expected the upgrade to be rejected")
        } catch let error as WebSocketError {
            guard case .handshakeFailed(let metadata, _) = error else {
                Issue.record("Expected handshakeFailed, got \(error)")
                return
            }
            #expect(metadata.statusCode == 401)
            #expect(metadata.url?.path == "/private/socket")
            #expect(metadata.value(forHTTPHeaderField: "WWW-Authenticate")
                == "Bearer realm=loopback")
            #expect(metadata.value(forHTTPHeaderField: "X-Rejection")
                == "test-fixture")
        }

        await server.waitForCompletion()
        await delegate.completionSignal.wait()
        #expect(server.snapshot.requestTarget == "/private/socket")
        #expect(server.snapshot.failureDescription == nil)
        #expect(delegate.snapshot.openedSubprotocols.isEmpty)
        #expect(delegate.snapshot.closes.isEmpty)
        #expect(delegate.snapshot.completionCount == 1)
        #expect(delegate.snapshot.completionErrorDescriptions.first
            .flatMap { $0 } != nil)
        delegate.snapshot.expectOneTaskAcrossEveryCallback(
            expectedOpenCount: 0,
            expectedCloseCount: 0
        )
    }

    private static func makeSession(
        delegate: RecordingWebSocketSessionDelegate? = nil
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }
}

private struct LoopbackSocketRequest: WebSocketRequest {
    let path: String
    let queryItems: [URLQueryItem]?
    let headers: [String: String]?
    let subprotocols: [String]

    init(
        path: String = "socket",
        queryItems: [URLQueryItem]? = nil,
        headers: [String: String]? = nil,
        subprotocols: [String] = []
    ) {
        self.path = path
        self.queryItems = queryItems
        self.headers = headers
        self.subprotocols = subprotocols
    }

    func customize(_ request: inout URLRequest) throws {
        request.timeoutInterval = 5
    }
}

private final class RecordingWebSocketSessionDelegate: NSObject,
    URLSessionWebSocketDelegate,
    @unchecked Sendable {
    struct Snapshot: Sendable {
        let openedSubprotocols: [String?]
        let closes: [WebSocketClose]
        let completionCount: Int
        let completionErrorDescriptions: [String?]
        let createdTaskIdentifiers: [Int]
        let metricsTaskIdentifiers: [Int]
        let openedTaskIdentifiers: [Int]
        let closedTaskIdentifiers: [Int]
        let completedTaskIdentifiers: [Int]

        func expectOneTaskAcrossEveryCallback(
            expectedOpenCount: Int = 1,
            expectedCloseCount: Int = 1
        ) {
            #expect(createdTaskIdentifiers.count == 1)
            #expect(metricsTaskIdentifiers.count == 1)
            #expect(openedTaskIdentifiers.count == expectedOpenCount)
            #expect(closedTaskIdentifiers.count == expectedCloseCount)
            #expect(completedTaskIdentifiers.count == 1)

            let identifiers = createdTaskIdentifiers
                + metricsTaskIdentifiers
                + openedTaskIdentifiers
                + closedTaskIdentifiers
                + completedTaskIdentifiers
            #expect(Set(identifiers).count == 1)
        }
    }

    private struct State {
        var openedSubprotocols: [String?] = []
        var closes: [WebSocketClose] = []
        var completionErrorDescriptions: [String?] = []
        var createdTaskIdentifiers: [Int] = []
        var metricsTaskIdentifiers: [Int] = []
        var openedTaskIdentifiers: [Int] = []
        var closedTaskIdentifiers: [Int] = []
        var completedTaskIdentifiers: [Int] = []
    }

    let completionSignal = AsyncSignal()
    private let state = LockedBox(State())

    var snapshot: Snapshot {
        state.withLock { state in
            Snapshot(
                openedSubprotocols: state.openedSubprotocols,
                closes: state.closes,
                completionCount: state.completionErrorDescriptions.count,
                completionErrorDescriptions: state.completionErrorDescriptions,
                createdTaskIdentifiers: state.createdTaskIdentifiers,
                metricsTaskIdentifiers: state.metricsTaskIdentifiers,
                openedTaskIdentifiers: state.openedTaskIdentifiers,
                closedTaskIdentifiers: state.closedTaskIdentifiers,
                completedTaskIdentifiers: state.completedTaskIdentifiers
            )
        }
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        state.withLock {
            $0.createdTaskIdentifiers.append(task.taskIdentifier)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        state.withLock {
            $0.metricsTaskIdentifiers.append(task.taskIdentifier)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        state.withLock {
            $0.openedSubprotocols.append(`protocol`)
            $0.openedTaskIdentifiers.append(webSocketTask.taskIdentifier)
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        state.withLock { state in
            state.closes.append(WebSocketClose(
                code: WebSocketCloseCode(rawValue: closeCode.rawValue),
                reason: reason
            ))
            state.closedTaskIdentifiers.append(webSocketTask.taskIdentifier)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        state.withLock {
            $0.completionErrorDescriptions.append(error?.localizedDescription)
            $0.completedTaskIdentifiers.append(task.taskIdentifier)
        }
        Task { await completionSignal.signal() }
    }
}

private enum LoopbackTimeoutError: LocalizedError, Sendable {
    case timedOut

    var errorDescription: String? {
        "The loopback WebSocket operation timed out."
    }
}

private func withLoopbackTimeout<Value: Sendable>(
    nanoseconds: UInt64 = 5_000_000_000,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: nanoseconds)
            throw LoopbackTimeoutError.timedOut
        }

        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw LoopbackTimeoutError.timedOut
        }
        return result
    }
}
