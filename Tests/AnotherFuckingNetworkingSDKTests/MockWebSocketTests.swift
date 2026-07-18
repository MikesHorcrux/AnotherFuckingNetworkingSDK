import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK
@testable import AnotherFuckingNetworkingSDKTesting

@Suite("MockWebSocketClient")
struct MockWebSocketClientTests {
    @Test("Type-wide connections support protocol injection")
    func typeWideConnection() async throws {
        let mock = MockWebSocketClient()
        let expected = MockWebSocketConnection(
            url: URL(string: "wss://mock.invalid/type")!
        )
        await mock.stub(MockSocketRequest.self, with: expected)
        let client: any WebSocketClientProtocol = mock

        let connection = try await client.connect(MockSocketRequest(value: "one"))

        #expect(connection.url == expected.url)
    }

    @Test("Exact stubs override type defaults and latest registrations win")
    func exactPrecedenceAndLatestWins() async throws {
        let mock = MockWebSocketClient()
        let request = MockSocketRequest(value: "exact")
        let fallback = MockWebSocketConnection(
            url: URL(string: "wss://mock.invalid/fallback")!
        )
        let first = MockWebSocketConnection(
            url: URL(string: "wss://mock.invalid/first")!
        )
        let latest = MockWebSocketConnection(
            url: URL(string: "wss://mock.invalid/latest")!
        )
        await mock.stub(MockSocketRequest.self, with: fallback)
        try await mock.stub(request, with: first)
        try await mock.stub(request, with: latest)

        #expect(try await mock.connect(request).url == latest.url)
        #expect(try await mock.connect(
            MockSocketRequest(value: "other")
        ).url == fallback.url)
    }

    @Test("Exact matching uses the final URLRequest and socket options")
    func exactFinalRequestMatching() async throws {
        let mock = MockWebSocketClient(
            baseURL: URL(string: "https://example.com/api?locale=en"),
            globalHeaders: ["Authorization": "Bearer fixture"]
        )
        let firstRequest = MockSocketRequest(value: "one", maximumSize: 128)
        let secondRequest = MockSocketRequest(value: "two", maximumSize: 256)
        let first = MockWebSocketConnection(
            url: URL(string: "wss://mock.invalid/one")!
        )
        let second = MockWebSocketConnection(
            url: URL(string: "wss://mock.invalid/two")!
        )
        try await mock.stub(firstRequest, with: first)
        try await mock.stub(secondRequest, with: second)

        #expect(try await mock.connect(firstRequest).url == first.url)
        #expect(try await mock.connect(secondRequest).url == second.url)

        let records = await mock.recordedRequests
        #expect(records.map(\.url.absoluteString) == [
            "wss://example.com/api/socket?locale=en&value=one&signed=one",
            "wss://example.com/api/socket?locale=en&value=two&signed=two"
        ])
        #expect(records.map { $0.headers["authorization"] } == [
            "Bearer fixture", "Bearer fixture"
        ])
        #expect(records.map { $0.headers["x-signature"] } == ["one", "two"])
        #expect(records.map(\.subprotocols) == [["chat.v1"], ["chat.v1"]])
        #expect(records.map(\.maximumMessageSize) == [128, 256])
    }

    @Test("Factories run for every connection")
    func factoryCreatesIndependentConnections() async throws {
        let sequence = LockedBox(0)
        let mock = MockWebSocketClient()
        await mock.stub(MockSocketRequest.self) { _ in
            let id = sequence.withLock { value in
                value += 1
                return value
            }
            return MockWebSocketConnection(
                url: URL(string: "wss://mock.invalid/\(id)")!
            )
        }

        let first = try await mock.connect(MockSocketRequest(value: "one"))
        let second = try await mock.connect(MockSocketRequest(value: "two"))

        #expect(first.url.absoluteString == "wss://mock.invalid/1")
        #expect(second.url.absoluteString == "wss://mock.invalid/2")
    }

    @Test("Failures, missing stubs, delays, and reset are deterministic")
    func failuresDelayAndReset() async throws {
        let capturedDelay = LockedBox<UInt64?>(nil)
        let mock = MockWebSocketClient(delay: 0.25) { nanoseconds in
            capturedDelay.withLock { $0 = nanoseconds }
        }
        await mock.stubError(
            MockSocketRequest.self,
            error: MockSocketFixtureError.stubbed
        )

        do {
            _ = try await mock.connect(MockSocketRequest(value: "failure"))
            Issue.record("Expected the registered failure")
        } catch let error as MockSocketFixtureError {
            #expect(error == .stubbed)
        }
        #expect(capturedDelay.withLock { $0 } == 250_000_000)

        await mock.reset()
        do {
            _ = try await mock.connect(MockSocketRequest(value: "missing"))
            Issue.record("Expected a missing-stub error")
        } catch let error as MockWebSocketClientError {
            guard case .missingStub(let request) = error else {
                Issue.record("Expected missingStub, got \(error)")
                return
            }
            #expect(request.sequenceID == 1)
            #expect(request.path == "socket")
        }
    }

    @Test("Cancellation remains CancellationError")
    func cancellationPrecedence() async {
        let mock = MockWebSocketClient()
        await mock.stubError(
            MockSocketRequest.self,
            error: CancellationError()
        )

        do {
            _ = try await mock.connect(MockSocketRequest(value: "cancel"))
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }
}

@Suite("MockWebSocketConnection")
struct MockWebSocketConnectionTests {
    @Test("Incoming messages are FIFO and concurrent receives match production")
    func receiveFIFOAndConcurrencyParity() async throws {
        let mock = MockWebSocketConnection()
        let first = Task { try await mock.receive() }
        await expectPendingReceives(1, on: mock)

        do {
            _ = try await mock.receive()
            Issue.record("Expected concurrentReceive")
        } catch let error as WebSocketError {
            guard case .concurrentReceive = error else {
                Issue.record("Expected concurrentReceive, got \(error)")
                return
            }
        }

        await mock.enqueueIncoming(text: "first")
        await mock.enqueueIncoming(data: Data([0x02]))

        #expect(try await first.value == .text("first"))
        #expect(try await mock.receive() == .binary(Data([0x02])))
        #expect(await mock.pendingReceiveCount == 0)
    }

    @Test("Receive cancellation closes the connection")
    func receiveCancellation() async throws {
        let mock = MockWebSocketConnection()
        let cancelled = Task { try await mock.receive() }
        await expectPendingReceives(1, on: mock)

        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        await expectPendingReceives(0, on: mock)
        #expect(await mock.state == .closed(nil))

        do {
            _ = try await mock.receive()
            Issue.record("Expected the cancelled connection to stay closed")
        } catch let error as WebSocketError {
            guard case .connectionClosed(nil) = error else {
                Issue.record("Expected connectionClosed, got \(error)")
                return
            }
        }
    }

    @Test("Queued operation failures close their connections")
    func queuedOperationFailuresAreTerminal() async throws {
        let sendMock = MockWebSocketConnection()
        await sendMock.enqueueSendResult(.failure(MockSocketFixtureError.send))

        do {
            try await sendMock.send(text: "failed")
            Issue.record("Expected send failure")
        } catch let error as MockSocketFixtureError {
            #expect(error == .send)
        }
        #expect(await sendMock.state == .closed(nil))

        let pingMock = MockWebSocketConnection()
        await pingMock.enqueuePingResult(.failure(MockSocketFixtureError.ping))
        do {
            try await pingMock.ping()
            Issue.record("Expected ping failure")
        } catch let error as MockSocketFixtureError {
            #expect(error == .ping)
        }
        #expect(await pingMock.state == .closed(nil))
        #expect(await sendMock.sentMessages == [.text("failed")])
        #expect(await pingMock.pingCount == 1)
    }

    @Test("A cancelled task can still request a graceful close")
    func cancelledTaskCanClose() async throws {
        let mock = MockWebSocketConnection()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await mock.close(code: .normalClosure, reason: nil)
        }

        try await task.value
        #expect(await mock.state == .closing)
    }

    @Test("Close validates inputs, records details, and drains receivers")
    func closeLifecycle() async throws {
        let mock = MockWebSocketConnection()
        let receive = Task { try await mock.receive() }
        await expectPendingReceives(1, on: mock)

        do {
            try await mock.close(
                code: WebSocketCloseCode(rawValue: 2_999),
                reason: nil
            )
            Issue.record("Expected invalid close code")
        } catch let error as WebSocketError {
            guard case .invalidCloseCode(2_999) = error else {
                Issue.record("Expected invalidCloseCode, got \(error)")
                return
            }
        }

        try await mock.close(code: .normalClosure, reason: "Done")

        #expect(await mock.state == .closing)
        #expect(await mock.closeDetails == WebSocketClose(
            code: .normalClosure,
            reason: Data("Done".utf8)
        ))
        do {
            _ = try await receive.value
            Issue.record("Expected closing error")
        } catch let error as WebSocketError {
            guard case .connectionClosing = error else {
                Issue.record("Expected connectionClosing, got \(error)")
                return
            }
        }
    }

    @Test("Normal finish ends the asynchronous message sequence")
    func cleanSequenceFinish() async throws {
        let mock = MockWebSocketConnection()
        var iterator = mock.messages.makeAsyncIterator()
        let next = Task { try await iterator.next() }
        await expectPendingReceives(1, on: mock)

        await mock.finish(with: .normalClosure)

        #expect(try await next.value == nil)
        #expect(await mock.state == .closed(WebSocketClose(
            code: .normalClosure
        )))
    }

    @Test("Failure drains receivers and is reused by future operations")
    func terminalFailure() async throws {
        let mock = MockWebSocketConnection()
        let receive = Task { try await mock.receive() }
        await expectPendingReceives(1, on: mock)

        await mock.fail(with: MockSocketFixtureError.terminal)

        for operation in [
            { try await receive.value },
            { try await mock.receive() }
        ] {
            do {
                _ = try await operation()
                Issue.record("Expected terminal failure")
            } catch let error as MockSocketFixtureError {
                #expect(error == .terminal)
            }
        }
    }

    @Test("Reset cancels waiters and returns to a fresh open state")
    func reset() async throws {
        let mock = MockWebSocketConnection()
        try await mock.send(text: "before")
        let receive = Task { try await mock.receive() }
        await expectPendingReceives(1, on: mock)

        await mock.reset()

        do {
            _ = try await receive.value
            Issue.record("Expected reset cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await mock.state == .open)
        #expect(await mock.recordedOperations.isEmpty)
        #expect(await mock.pendingReceiveCount == 0)

        await mock.enqueueIncoming(text: "after")
        #expect(try await mock.receive() == .text("after"))
    }

    @Test("Unified records preserve cross-operation order")
    func unifiedOperationOrder() async throws {
        let mock = MockWebSocketConnection()
        try await mock.send(text: "hello")
        await mock.enqueueIncoming(text: "world")
        _ = try await mock.receive()
        try await mock.ping()
        try await mock.close(code: .goingAway, reason: nil)

        let records = await mock.recordedOperations
        #expect(records.map(\.sequenceID) == [0, 1, 2, 3])
        #expect(records.map(\.operation) == [
            .send(.text("hello")),
            .receive,
            .ping,
            .close(WebSocketClose(code: .goingAway))
        ])
    }
}

private struct MockSocketRequest: WebSocketRequest {
    let value: String
    var maximumSize: Int? = nil

    var path: String { "socket" }
    var queryItems: [URLQueryItem]? {
        [URLQueryItem(name: "value", value: value)]
    }
    var subprotocols: [String] { ["chat.v1"] }
    var maximumMessageSize: Int? { maximumSize }

    func customize(_ request: inout URLRequest) throws {
        request.setValue(value, forHTTPHeaderField: "X-Signature")
        guard let url = request.url,
              var components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
              ) else {
            throw WebSocketError.invalidURL
        }
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "signed", value: value)
        ]
        request.url = components.url
    }
}

private enum MockSocketFixtureError: Error, Equatable, Sendable {
    case stubbed
    case send
    case ping
    case terminal
}

private func expectPendingReceives(
    _ expected: Int,
    on connection: MockWebSocketConnection
) async {
    for _ in 0..<1_000 {
        if await connection.pendingReceiveCount == expected {
            return
        }
        await Task.yield()
    }
    Issue.record(
        "Expected \(expected) pending receive(s), got \(await connection.pendingReceiveCount)"
    )
}
