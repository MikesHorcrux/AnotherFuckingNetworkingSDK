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
        #expect(records.map(\.inboundBufferingPolicy) == [
            .default, .default
        ])
    }

    @Test("Exact stubs and records distinguish inbound buffering policies")
    func exactBufferingPolicyMatching() async throws {
        let compact = WebSocketInboundBufferingPolicy(
            maximumMessages: 2,
            maximumBytes: 128
        )
        let spacious = WebSocketInboundBufferingPolicy(
            maximumMessages: 8,
            maximumBytes: 4_096
        )
        let compactRequest = MockSocketRequest(
            value: "same",
            maximumSize: 512,
            bufferingPolicy: compact
        )
        let spaciousRequest = MockSocketRequest(
            value: "same",
            maximumSize: 512,
            bufferingPolicy: spacious
        )
        let compactConnection = MockWebSocketConnection(
            url: URL(string: "wss://mock.invalid/compact")!
        )
        let spaciousConnection = MockWebSocketConnection(
            url: URL(string: "wss://mock.invalid/spacious")!
        )
        let mock = MockWebSocketClient()

        try await mock.stub(compactRequest, with: compactConnection)
        try await mock.stub(spaciousRequest, with: spaciousConnection)

        #expect(try await mock.connect(compactRequest).url
            == compactConnection.url)
        #expect(try await mock.connect(spaciousRequest).url
            == spaciousConnection.url)
        #expect(await mock.recordedRequests.map(\.inboundBufferingPolicy)
            == [compact, spacious])
    }

    @Test("Exact registration and connection snapshot options once each")
    func requestOptionsAreSnapshottedOnce() async throws {
        let request = CountingMockSocketRequest()
        let connection = MockWebSocketConnection()
        let mock = MockWebSocketClient()

        try await mock.stub(request, with: connection)
        #expect(request.readCounts == .init(
            maximumMessageSize: 1,
            inboundBufferingPolicy: 1
        ))

        _ = try await mock.connect(request)
        #expect(request.readCounts == .init(
            maximumMessageSize: 2,
            inboundBufferingPolicy: 2
        ))
    }

    @Test("The legacy request record initializer retains default limits")
    func legacyRequestRecordInitializer() throws {
        let url = try #require(URL(string: "wss://mock.invalid/socket"))
        let record = RecordedWebSocketRequest(
            sequenceID: 0,
            requestTypeID: ObjectIdentifier(MockSocketRequest.self),
            requestTypeName: "MockSocketRequest",
            urlRequest: URLRequest(url: url),
            url: url,
            path: "socket",
            queryItems: [],
            headers: [:],
            subprotocols: [],
            maximumMessageSize: nil
        )

        #expect(record.inboundBufferingPolicy == .default)
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
    @Test("Legacy and validating initializers expose stable policies")
    func bufferingPolicyInitializers() async throws {
        let legacy = MockWebSocketConnection()
        #expect(legacy.inboundBufferingPolicy == .default)

        let custom = WebSocketInboundBufferingPolicy(
            maximumMessages: 3,
            maximumBytes: 2_048
        )
        let configured = try MockWebSocketConnection(
            inboundBufferingPolicy: custom
        )
        #expect(configured.inboundBufferingPolicy == custom)

        for invalid in [
            WebSocketInboundBufferingPolicy(
                maximumMessages: 0,
                maximumBytes: 1
            ),
            WebSocketInboundBufferingPolicy(
                maximumMessages: 1,
                maximumBytes: 0
            ),
        ] {
            do {
                _ = try MockWebSocketConnection(
                    inboundBufferingPolicy: invalid
                )
                Issue.record("Expected invalid buffering policy")
            } catch let error as WebSocketError {
                guard case .invalidInboundBufferingPolicy(let policy) =
                    error else {
                    Issue.record("Expected invalid policy, got \(error)")
                    continue
                }
                #expect(policy == invalid)
            }
        }
    }

    @Test("Initial overflow preserves its accepted prefix")
    func initialOverflowPreservesPrefix() async throws {
        let policy = WebSocketInboundBufferingPolicy(
            maximumMessages: 2,
            maximumBytes: 1_024
        )
        let accepted: [WebSocketMessage] = [
            .text("one"),
            .binary(Data([0x02, 0x03])),
        ]
        let mock = try MockWebSocketConnection(
            inboundBufferingPolicy: policy,
            incoming: (accepted + [.text("rejected")]).map {
                .success($0)
            }
        )

        #expect(await mock.state == .closed(nil))
        #expect(await mock.bufferedMessageCount == 2)
        #expect(await mock.bufferedByteCount == 5)
        #expect(try await mock.receive() == accepted[0])
        #expect(try await mock.receive() == accepted[1])

        do {
            _ = try await mock.receive()
            Issue.record("Expected inbound overflow")
        } catch let error as WebSocketError {
            guard case .inboundBufferOverflow(let overflow) = error else {
                Issue.record("Expected inbound overflow, got \(error)")
                return
            }
            #expect(overflow == WebSocketInboundBufferOverflow(
                policy: policy,
                bufferedMessageCount: 2,
                bufferedByteCount: 5,
                incomingMessageByteCount: 8
            ))
        }
        #expect(await mock.bufferedMessageCount == 0)
        #expect(await mock.bufferedByteCount == 0)
    }

    @Test("Enqueued byte overflow counts UTF-8 and binary payloads")
    func enqueuedByteOverflow() async throws {
        let policy = WebSocketInboundBufferingPolicy(
            maximumMessages: 4,
            maximumBytes: 5
        )
        let mock = try MockWebSocketConnection(
            inboundBufferingPolicy: policy
        )
        await mock.enqueueIncoming(text: "é")
        await mock.enqueueIncoming(data: Data([0x01, 0x02, 0x03]))
        await mock.enqueueIncoming(text: "!")

        #expect(await mock.state == .closed(nil))
        #expect(await mock.bufferedMessageCount == 2)
        #expect(await mock.bufferedByteCount == 5)
        #expect(try await mock.receive() == .text("é"))
        #expect(try await mock.receive() == .binary(
            Data([0x01, 0x02, 0x03])
        ))

        let expectedOverflow = WebSocketInboundBufferOverflow(
            policy: policy,
            bufferedMessageCount: 2,
            bufferedByteCount: 5,
            incomingMessageByteCount: 1
        )
        for _ in 0..<2 {
            do {
                _ = try await mock.receive()
                Issue.record("Expected stable inbound overflow")
            } catch let error as WebSocketError {
                guard case .inboundBufferOverflow(let overflow) = error else {
                    Issue.record("Expected inbound overflow, got \(error)")
                    continue
                }
                #expect(overflow == expectedOverflow)
            }
        }

        let lateClose = WebSocketClose(code: .policyViolation)
        await mock.finish(with: lateClose)
        #expect(await mock.state == .closed(lateClose))
        do {
            _ = try await mock.receive()
            Issue.record("Expected overflow after close refinement")
        } catch let error as WebSocketError {
            guard case .inboundBufferOverflow(let overflow) = error else {
                Issue.record("Expected inbound overflow, got \(error)")
                return
            }
            #expect(overflow == expectedOverflow)
        }
    }

    @Test("A waiting receiver bypasses aggregate retention limits")
    func directDeliveryBypassesLimits() async throws {
        let mock = try MockWebSocketConnection(
            inboundBufferingPolicy: .init(
                maximumMessages: 1,
                maximumBytes: 1
            )
        )
        let receive = Task { try await mock.receive() }
        await expectPendingReceives(1, on: mock)

        await mock.enqueueIncoming(text: "larger than the buffer")

        #expect(try await receive.value == .text("larger than the buffer"))
        #expect(await mock.state == .open)
        #expect(await mock.bufferedMessageCount == 0)
        #expect(await mock.bufferedByteCount == 0)
    }

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

    @Test("Close validates inputs and pending receives await peer completion")
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
            _ = try await mock.receive()
            Issue.record("Expected a new receive to reject closing state")
        } catch let error as WebSocketError {
            guard case .connectionClosing = error else {
                Issue.record("Expected connectionClosing, got \(error)")
                return
            }
        }

        #expect(await mock.pendingReceiveCount == 1)
        let peerClose = WebSocketClose(
            code: .normalClosure,
            reason: Data("Done".utf8)
        )
        await mock.finish(with: peerClose)
        do {
            _ = try await receive.value
            Issue.record("Expected peer closure")
        } catch let error as WebSocketError {
            guard case .connectionClosed(let close) = error else {
                Issue.record("Expected connectionClosed, got \(error)")
                return
            }
            #expect(close == peerClose)
        }
    }

    @Test("Lifecycle states are pushed in order and finish after closure")
    func lifecycleStates() async throws {
        let mock = MockWebSocketConnection()
        let states = mock.states
        requireSendable(states)
        var firstIterator = states.makeAsyncIterator()
        var secondIterator = states.makeAsyncIterator()
        var slowIterator = states.makeAsyncIterator()

        #expect(await firstIterator.next() == .open)
        #expect(await secondIterator.next() == .open)
        #expect(await slowIterator.next() == .open)

        try await mock.close(code: .normalClosure, reason: "Done")
        #expect(await firstIterator.next() == .closing)
        #expect(await secondIterator.next() == .closing)

        let peerClose = WebSocketClose(
            code: .normalClosure,
            reason: Data("Done".utf8)
        )
        await mock.finish(with: peerClose)

        #expect(await firstIterator.next() == .closed(peerClose))
        #expect(await secondIterator.next() == .closed(peerClose))
        #expect(await slowIterator.next() == .closed(peerClose))
        #expect(await firstIterator.next() == nil)
        #expect(await secondIterator.next() == nil)
        #expect(await slowIterator.next() == nil)

        var lateIterator = states.makeAsyncIterator()
        #expect(await lateIterator.next() == .closed(peerClose))
        #expect(await lateIterator.next() == nil)

        await mock.reset()
        #expect(await firstIterator.next() == nil)
        var resetIterator = states.makeAsyncIterator()
        #expect(await resetIterator.next() == .open)
    }

    @available(iOS 17.0, macOS 14.0, *)
    @MainActor
    @Test("Observation adapter follows mock lifecycle states")
    func observableLifecycleState() async throws {
        let mock = MockWebSocketConnection()
        let observable = ObservableWebSocketState(connection: mock)

        #expect(observable.state == .open)

        try await mock.close(code: .normalClosure, reason: nil)
        await expectObservableState(.closing, on: observable)

        let peerClose = WebSocketClose(code: .normalClosure)
        await mock.finish(with: peerClose)
        await expectObservableState(.closed(peerClose), on: observable)

        #expect(observable.isOpen == false)
        #expect(observable.isClosing == false)
        #expect(observable.close == peerClose)
        observable.stop()

        await mock.reset()
        let stoppedObservable = ObservableWebSocketState(connection: mock)
        stoppedObservable.stop()
        try await mock.close(code: .normalClosure, reason: nil)
        for _ in 0..<10 {
            await Task.yield()
        }
        #expect(stoppedObservable.state == .open)
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

    @Test("Normal finish and failure preserve buffered prefixes")
    func terminalStatesPreserveBufferedPrefixes() async throws {
        let cleanMessages: [WebSocketMessage] = [
            .text("clean-one"),
            .binary(Data([0xca, 0xfe])),
        ]
        let clean = MockWebSocketConnection(
            incoming: cleanMessages.map { .success($0) }
        )
        await clean.finish(with: .normalClosure)
        var cleanIterator = clean.messages.makeAsyncIterator()
        #expect(try await cleanIterator.next() == cleanMessages[0])
        #expect(try await cleanIterator.next() == cleanMessages[1])
        #expect(try await cleanIterator.next() == nil)

        let failedMessages: [WebSocketMessage] = [
            .text("failed-one"),
            .text("failed-two"),
        ]
        let failed = MockWebSocketConnection(
            incoming: failedMessages.map { .success($0) }
        )
        await failed.fail(with: MockSocketFixtureError.terminal)
        #expect(try await failed.receive() == failedMessages[0])
        #expect(try await failed.receive() == failedMessages[1])
        do {
            _ = try await failed.receive()
            Issue.record("Expected terminal failure after buffered prefix")
        } catch let error as MockSocketFixtureError {
            #expect(error == .terminal)
        }

        let initiallyFailed = MockWebSocketConnection(incoming: [
            .success(.text("before-initial-failure")),
            .failure(MockSocketFixtureError.terminal),
            .success(.text("ignored-after-failure")),
        ])
        #expect(await initiallyFailed.state == .closed(nil))
        #expect(await initiallyFailed.bufferedMessageCount == 1)
        #expect(try await initiallyFailed.receive()
            == .text("before-initial-failure"))
        do {
            _ = try await initiallyFailed.receive()
            Issue.record("Expected the initial terminal failure")
        } catch let error as MockSocketFixtureError {
            #expect(error == .terminal)
        }
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

    @Test("Late peer close details refine non-overflow receive failures")
    func lateCloseRefinesTerminalReceiveFailure() async throws {
        let mock = MockWebSocketConnection()
        await mock.fail(with: MockSocketFixtureError.terminal)

        let peerClose = WebSocketClose(
            code: .goingAway,
            reason: Data("peer shutdown".utf8)
        )
        await mock.finish(with: peerClose)

        #expect(await mock.state == .closed(peerClose))
        #expect(await mock.closeDetails == peerClose)
        do {
            _ = try await mock.receive()
            Issue.record("Expected refined peer closure")
        } catch let error as WebSocketError {
            guard case .connectionClosed(let close) = error else {
                Issue.record("Expected connectionClosed, got \(error)")
                return
            }
            #expect(close == peerClose)
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

    @Test("Reset clears buffered terminal state and retains policy")
    func resetRetainsBufferingPolicy() async throws {
        let policy = WebSocketInboundBufferingPolicy(
            maximumMessages: 2,
            maximumBytes: 4
        )
        let mock = try MockWebSocketConnection(
            inboundBufferingPolicy: policy
        )
        await mock.enqueueIncoming(text: "é")
        await mock.enqueueIncoming(error: MockSocketFixtureError.terminal)

        #expect(await mock.state == .closed(nil))
        #expect(await mock.bufferedMessageCount == 1)
        #expect(await mock.bufferedByteCount == 2)

        await mock.reset()

        #expect(mock.inboundBufferingPolicy == policy)
        #expect(await mock.state == .open)
        #expect(await mock.bufferedMessageCount == 0)
        #expect(await mock.bufferedByteCount == 0)
        await mock.enqueueIncoming(text: "ok")
        #expect(try await mock.receive() == .text("ok"))
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
    var bufferingPolicy: WebSocketInboundBufferingPolicy = .default

    var path: String { "socket" }
    var queryItems: [URLQueryItem]? {
        [URLQueryItem(name: "value", value: value)]
    }
    var subprotocols: [String] { ["chat.v1"] }
    var maximumMessageSize: Int? { maximumSize }
    var inboundBufferingPolicy: WebSocketInboundBufferingPolicy {
        bufferingPolicy
    }

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

private final class CountingMockSocketRequest:
    WebSocketRequest,
    @unchecked Sendable {
    struct ReadCounts: Equatable, Sendable {
        let maximumMessageSize: Int
        let inboundBufferingPolicy: Int
    }

    private struct State {
        var maximumMessageSize = 0
        var inboundBufferingPolicy = 0
    }

    let path = "socket"
    private let state = LockedBox(State())

    var maximumMessageSize: Int? {
        state.withLock { state in
            state.maximumMessageSize += 1
            return 1_024
        }
    }

    var inboundBufferingPolicy: WebSocketInboundBufferingPolicy {
        state.withLock { state in
            state.inboundBufferingPolicy += 1
            return .init(maximumMessages: 4, maximumBytes: 4_096)
        }
    }

    var readCounts: ReadCounts {
        state.withLock { state in
            ReadCounts(
                maximumMessageSize: state.maximumMessageSize,
                inboundBufferingPolicy: state.inboundBufferingPolicy
            )
        }
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

@available(iOS 17.0, macOS 14.0, *)
@MainActor
private func expectObservableState(
    _ expected: WebSocketConnectionState,
    on observable: ObservableWebSocketState
) async {
    for _ in 0..<1_000 {
        if observable.state == expected {
            return
        }
        await Task.yield()
    }
    Issue.record(
        "Expected observable state \(expected), got \(observable.state)"
    )
}

private func requireSendable<Value: Sendable>(_ value: Value) {}
