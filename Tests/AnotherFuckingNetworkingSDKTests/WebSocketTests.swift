import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("WebSocket request construction")
struct WebSocketRequestBuilderTests {
    @Test("Handshake construction preserves URL components and configuration")
    func completeHandshakeRequest() throws {
        let request = WebSocketFixtureRequest(
            path: "chat rooms/42",
            queryItems: [URLQueryItem(name: "format", value: "json")],
            headers: [
                "authorization": "request-token",
                "X-Request": "request-value"
            ],
            subprotocols: ["chat.v2", "json+patch"],
            maximumMessageSize: 1_024,
            customization: .valid
        )

        let urlRequest = try WebSocketRequestBuilder.make(
            request,
            baseURL: URL(string: "https://example.com/api?locale=en"),
            globalHeaders: [
                "Authorization": "global-token",
                "X-Global": "global-value"
            ]
        )

        #expect(urlRequest.url?.absoluteString
            == "wss://example.com/api/chat%20rooms/42?locale=en&format=json")
        #expect(urlRequest.httpMethod == "GET")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization")
            == "request-token")
        #expect(urlRequest.value(forHTTPHeaderField: "X-Global")
            == "global-value")
        #expect(urlRequest.value(forHTTPHeaderField: "X-Request")
            == "request-value")
        #expect(urlRequest.value(forHTTPHeaderField: "X-Custom")
            == "custom-value")
        #expect(urlRequest.value(forHTTPHeaderField: "Sec-WebSocket-Protocol")
            == "chat.v2, json+patch")
        #expect(urlRequest.timeoutInterval == 17)
        #expect(urlRequest.httpBody == nil)
    }

    @Test("Global request customization refines a validated upgrade")
    func globalRequestCustomization() throws {
        let urlRequest = try WebSocketRequestBuilder.make(
            WebSocketFixtureRequest(path: "chat"),
            baseURL: URL(string: "https://example.com"),
            globalHeaders: [:],
            requestCustomizer: { request in
                #expect(request.httpMethod == "GET")
                request.setValue("trace-42", forHTTPHeaderField: "X-Trace-ID")
            }
        )

        #expect(urlRequest.value(forHTTPHeaderField: "X-Trace-ID") == "trace-42")
        #expect(urlRequest.httpMethod == "GET")
        #expect(urlRequest.httpBody == nil)
    }

    @Test("Global WebSocket customization cannot invalidate handshake fields")
    func globalRequestCustomizationValidation() {
        let error = requireWebSocketError {
            try WebSocketRequestBuilder.make(
                WebSocketFixtureRequest(),
                baseURL: URL(string: "https://example.com"),
                globalHeaders: [:],
                requestCustomizer: { request in
                    request.setValue("websocket", forHTTPHeaderField: "Upgrade")
                }
            )
        }

        guard case .reservedHeader(let name)? = error else {
            Issue.record("Expected reservedHeader, got \(String(describing: error))")
            return
        }
        #expect(name == "upgrade")
    }

    @Test("HTTP schemes are converted and WebSocket schemes are retained")
    func supportedSchemes() throws {
        let cases = [
            ("http", "ws"),
            ("https", "wss"),
            ("ws", "ws"),
            ("wss", "wss")
        ]

        for (sourceScheme, expectedScheme) in cases {
            let request = try WebSocketRequestBuilder.make(
                WebSocketFixtureRequest(path: "socket"),
                baseURL: URL(string: "\(sourceScheme)://example.com/api"),
                globalHeaders: [:]
            )

            #expect(request.url?.scheme == expectedScheme)
            #expect(request.url?.path == "/api/socket")
        }
    }

    @Test("Decoded and percent-encoded paths remain distinct")
    func pathEncoding() throws {
        let baseURL = try #require(URL(string: "https://example.com"))
        let decoded = try WebSocketRequestBuilder.make(
            WebSocketFixtureRequest(path: "rooms%2F42"),
            baseURL: baseURL,
            globalHeaders: [:]
        )
        let encoded = try WebSocketRequestBuilder.make(
            WebSocketFixtureRequest(
                path: "rooms%2F42",
                pathEncoding: .percentEncoded
            ),
            baseURL: baseURL,
            globalHeaders: [:]
        )

        #expect(decoded.url?.absoluteString
            == "wss://example.com/rooms%252F42")
        #expect(encoded.url?.absoluteString
            == "wss://example.com/rooms%2F42")

        let error = requireWebSocketError {
            try WebSocketRequestBuilder.make(
                WebSocketFixtureRequest(
                    path: "rooms/Jane Doe",
                    pathEncoding: .percentEncoded
                ),
                baseURL: baseURL,
                globalHeaders: [:]
            )
        }
        guard case .invalidURL? = error else {
            Issue.record("Expected invalidURL, got \(String(describing: error))")
            return
        }
    }

    @Test("Missing and unsupported base URLs are rejected")
    func invalidURLs() {
        for baseURL in [nil, URL(string: "ftp://example.com")] {
            let error = requireWebSocketError {
                try WebSocketRequestBuilder.make(
                    WebSocketFixtureRequest(),
                    baseURL: baseURL,
                    globalHeaders: [:]
                )
            }
            guard case .invalidURL? = error else {
                Issue.record("Expected invalidURL, got \(String(describing: error))")
                continue
            }
        }
    }

    @Test("WebSocket URLs require a non-empty host")
    func emptyHost() throws {
        let hostlessURL = try #require(URL(string: "ws:/socket"))
        let error = requireWebSocketError {
            try WebSocketRequestBuilder.make(
                WebSocketFixtureRequest(customization: .url(hostlessURL)),
                baseURL: URL(string: "https://example.com"),
                globalHeaders: [:]
            )
        }

        guard case .invalidURL? = error else {
            Issue.record("Expected invalidURL, got \(String(describing: error))")
            return
        }
    }

    @Test("Maximum message size must be positive")
    func maximumMessageSizeValidation() {
        for size in [0, -1] {
            let error = requireWebSocketError {
                try WebSocketRequestBuilder.make(
                    WebSocketFixtureRequest(maximumMessageSize: size),
                    baseURL: URL(string: "https://example.com"),
                    globalHeaders: [:]
                )
            }
            guard case .invalidMaximumMessageSize(let actual)? = error else {
                Issue.record(
                    "Expected invalidMaximumMessageSize, got \(String(describing: error))"
                )
                continue
            }
            #expect(actual == size)
        }
    }

    @Test("Inbound buffering limits must be positive")
    func inboundBufferingValidation() {
        let policies = [
            WebSocketInboundBufferingPolicy(
                maximumMessages: 0,
                maximumBytes: 1
            ),
            WebSocketInboundBufferingPolicy(
                maximumMessages: 1,
                maximumBytes: 0
            ),
            WebSocketInboundBufferingPolicy(
                maximumMessages: -1,
                maximumBytes: -1
            ),
        ]

        for policy in policies {
            let error = requireWebSocketError {
                try WebSocketRequestBuilder.make(
                    WebSocketFixtureRequest(
                        inboundBufferingPolicy: policy
                    ),
                    baseURL: URL(string: "https://example.com"),
                    globalHeaders: [:]
                )
            }
            guard case .invalidInboundBufferingPolicy(let actual)? = error else {
                Issue.record(
                    "Expected invalidInboundBufferingPolicy, got \(String(describing: error))"
                )
                continue
            }
            #expect(actual == policy)
        }

        #expect(WebSocketInboundBufferingPolicy.default == .init(
            maximumMessages: 64,
            maximumBytes: 8 * 1_024 * 1_024
        ))
    }

    @Test("Subprotocols must be unique WebSocket tokens")
    func subprotocolValidation() {
        for value in ["", "chat protocol", "chat,json", "café"] {
            let error = requireWebSocketError {
                try WebSocketRequestBuilder.make(
                    WebSocketFixtureRequest(subprotocols: [value]),
                    baseURL: URL(string: "https://example.com"),
                    globalHeaders: [:]
                )
            }
            guard case .invalidSubprotocol(let actual)? = error else {
                Issue.record(
                    "Expected invalidSubprotocol, got \(String(describing: error))"
                )
                continue
            }
            #expect(actual == value)
        }

        let duplicateError = requireWebSocketError {
            try WebSocketRequestBuilder.make(
                WebSocketFixtureRequest(subprotocols: ["chat", "chat"]),
                baseURL: URL(string: "https://example.com"),
                globalHeaders: [:]
            )
        }
        guard case .duplicateSubprotocol(let value)? = duplicateError else {
            Issue.record(
                "Expected duplicateSubprotocol, got \(String(describing: duplicateError))"
            )
            return
        }
        #expect(value == "chat")
    }

    @Test("Caller headers cannot take over Foundation's handshake fields")
    func callerHeaderValidation() {
        let reservedHeaders = [
            "Connection",
            "Host",
            "Upgrade",
            "Sec-WebSocket-Accept",
            "Sec-WebSocket-Extensions",
            "Sec-WebSocket-Key",
            "Sec-WebSocket-Version"
        ]

        for name in reservedHeaders {
            let error = requireWebSocketError {
                try WebSocketRequestBuilder.make(
                    WebSocketFixtureRequest(),
                    baseURL: URL(string: "https://example.com"),
                    globalHeaders: [name: "caller-value"]
                )
            }
            guard case .reservedHeader(let actual)? = error else {
                Issue.record(
                    "Expected reservedHeader, got \(String(describing: error))"
                )
                continue
            }
            #expect(actual == name.lowercased())
        }

        let protocolError = requireWebSocketError {
            try WebSocketRequestBuilder.make(
                WebSocketFixtureRequest(
                    headers: ["SEC-WEBSOCKET-PROTOCOL": "chat"]
                ),
                baseURL: URL(string: "https://example.com"),
                globalHeaders: [:]
            )
        }
        guard case .conflictingSubprotocolHeader? = protocolError else {
            Issue.record(
                "Expected conflictingSubprotocolHeader, got \(String(describing: protocolError))"
            )
            return
        }
    }

    @Test("Final customization cannot invalidate the handshake")
    func finalCustomizationValidation() {
        let baseURL = URL(string: "https://example.com")

        let methodError = requireWebSocketError {
            try WebSocketRequestBuilder.make(
                WebSocketFixtureRequest(customization: .method("POST")),
                baseURL: baseURL,
                globalHeaders: [:]
            )
        }
        guard case .invalidHandshakeMethod? = methodError else {
            Issue.record(
                "Expected invalidHandshakeMethod, got \(String(describing: methodError))"
            )
            return
        }

        let bodyError = requireWebSocketError {
            try WebSocketRequestBuilder.make(
                WebSocketFixtureRequest(
                    customization: .body(Data("payload".utf8))
                ),
                baseURL: baseURL,
                globalHeaders: [:]
            )
        }
        guard case .handshakeBodyNotAllowed? = bodyError else {
            Issue.record(
                "Expected handshakeBodyNotAllowed, got \(String(describing: bodyError))"
            )
            return
        }

        let reservedError = requireWebSocketError {
            try WebSocketRequestBuilder.make(
                WebSocketFixtureRequest(
                    customization: .header("Upgrade", "websocket")
                ),
                baseURL: baseURL,
                globalHeaders: [:]
            )
        }
        guard case .reservedHeader(let name)? = reservedError else {
            Issue.record(
                "Expected reservedHeader, got \(String(describing: reservedError))"
            )
            return
        }
        #expect(name == "upgrade")

        let protocolError = requireWebSocketError {
            try WebSocketRequestBuilder.make(
                WebSocketFixtureRequest(
                    subprotocols: ["chat"],
                    customization: .header(
                        "Sec-WebSocket-Protocol",
                        "different"
                    )
                ),
                baseURL: baseURL,
                globalHeaders: [:]
            )
        }
        guard case .conflictingSubprotocolHeader? = protocolError else {
            Issue.record(
                "Expected conflictingSubprotocolHeader, got \(String(describing: protocolError))"
            )
            return
        }

        let urlError = requireWebSocketError {
            try WebSocketRequestBuilder.make(
                WebSocketFixtureRequest(
                    customization: .url(URL(string: "https://other.example")!)
                ),
                baseURL: baseURL,
                globalHeaders: [:]
            )
        }
        guard case .invalidURL? = urlError else {
            Issue.record("Expected invalidURL, got \(String(describing: urlError))")
            return
        }
    }

    @Test("Customization failures are wrapped while cancellation is preserved")
    func customizationErrors() {
        let wrapped = requireWebSocketError {
            try WebSocketRequestBuilder.make(
                WebSocketFixtureRequest(customization: .fail),
                baseURL: URL(string: "https://example.com"),
                globalHeaders: [:]
            )
        }
        guard case .requestConfigurationFailed(let underlying)? = wrapped else {
            Issue.record(
                "Expected requestConfigurationFailed, got \(String(describing: wrapped))"
            )
            return
        }
        #expect(underlying is WebSocketFixtureError)

        do {
            _ = try WebSocketRequestBuilder.make(
                WebSocketFixtureRequest(customization: .cancel),
                baseURL: URL(string: "https://example.com"),
                globalHeaders: [:]
            )
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }
}

@Suite("APIClient WebSocket integration")
struct APIClientWebSocketTests {
    @Test("WebSocket telemetry forwards task metrics after the handshake")
    func telemetryForwardsTaskMetrics() async throws {
        let events = LockedBox<[NetworkTelemetryEvent]>([])
        let transport = FakeWebSocketTransport()
        let client = APIClient(
            baseURL: URL(string: "https://example.com"),
            telemetry: NetworkTelemetry { event in
                events.withLock { $0.append(event) }
            },
            webSocketTransportFactory: { _, _, _ in transport }
        )

        _ = try await client.connect(WebSocketFixtureRequest())
        let snapshot = NetworkTaskMetricsSnapshot(
            fetchStart: Date(timeIntervalSince1970: 1),
            responseEnd: Date(timeIntervalSince1970: 2),
            requestDurationNanoseconds: 1_000
        )
        transport.emitTaskMetrics(snapshot)

        let matching = events.withLock {
            $0.filter { $0.phase == .taskMetrics }
        }
        #expect(matching.count == 1)
        #expect(matching.first?.kind == .webSocketHandshake)
        #expect(matching.first?.taskMetrics == snapshot)
    }

    @Test("Connect builds the handshake and waits for transport open")
    func connectRequestAndOpen() async throws {
        let bufferingPolicy = WebSocketInboundBufferingPolicy(
            maximumMessages: 12,
            maximumBytes: 32_768
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let capturedInput = LockedBox<CapturedWebSocketFactoryInput?>(nil)
        let didFinish = LockedBox(false)
        let transport = FakeWebSocketTransport(openResult: nil)
        let client = APIClient(
            baseURL: URL(string: "https://example.com/api?locale=en"),
            urlSession: session,
            globalHeaders: [
                "Authorization": "global-token",
                "X-Global": "global-value"
            ],
            requestCustomizer: { request in
                request.setValue("trace-42", forHTTPHeaderField: "X-Trace-ID")
            },
            webSocketTransportFactory: { session, request, configuration in
                capturedInput.withLock {
                    $0 = CapturedWebSocketFactoryInput(
                        session: session,
                        request: request,
                        configuration: configuration
                    )
                }
                return transport
            }
        )
        let task = Task {
            defer { didFinish.withLock { $0 = true } }
            return try await client.connect(WebSocketFixtureRequest(
                path: "live feed",
                queryItems: [URLQueryItem(name: "room", value: "42")],
                headers: [
                    "authorization": "request-token",
                    "X-Request": "request-value"
                ],
                subprotocols: ["chat.v2"],
                maximumMessageSize: 4_096,
                inboundBufferingPolicy: bufferingPolicy,
                customization: .valid
            ))
        }

        await transport.openStarted.wait()
        #expect(didFinish.withLock { $0 } == false)
        let captured = try #require(capturedInput.withLock { $0 })
        #expect(captured.session === session)
        #expect(captured.configuration.maximumMessageSize == 4_096)
        #expect(captured.configuration.inboundBufferingPolicy == bufferingPolicy)
        #expect(captured.request.url?.absoluteString
            == "wss://example.com/api/live%20feed?locale=en&room=42")
        #expect(captured.request.httpMethod == "GET")
        #expect(captured.request.value(forHTTPHeaderField: "Authorization")
            == "request-token")
        #expect(captured.request.value(forHTTPHeaderField: "X-Global")
            == "global-value")
        #expect(captured.request.value(forHTTPHeaderField: "X-Request")
            == "request-value")
        #expect(captured.request.value(forHTTPHeaderField: "X-Trace-ID")
            == "trace-42")
        #expect(captured.request.value(forHTTPHeaderField: "X-Custom")
            == "custom-value")
        #expect(captured.request.value(
            forHTTPHeaderField: "Sec-WebSocket-Protocol"
        ) == "chat.v2")
        #expect(captured.request.timeoutInterval == 17)

        transport.completeOpen(.success("chat.v2"))
        let connection = try await task.value

        #expect(didFinish.withLock { $0 })
        #expect(connection.url == captured.request.url)
        #expect(connection.negotiatedSubprotocol == "chat.v2")
        #expect(await connection.state == .open)
        #expect(transport.snapshot.openCount == 1)
    }

    @Test("Connect maps handshake URL errors")
    func connectURLError() async {
        let expected = URLError(.cannotConnectToHost)
        let transport = FakeWebSocketTransport(
            openResult: .failure(expected)
        )
        let client = APIClient(
            baseURL: URL(string: "https://example.com"),
            webSocketTransportFactory: { _, _, _ in transport }
        )

        let error = await requireWebSocketError {
            try await client.connect(WebSocketFixtureRequest())
        }
        guard case .transport(let underlying)? = error else {
            Issue.record(
                "Expected transport error, got \(String(describing: error))"
            )
            return
        }
        #expect(underlying.code == expected.code)
        #expect(transport.snapshot.cancelCount == 0)
    }

    @Test("Connect maps unknown handshake errors")
    func connectUnknownError() async {
        let transport = FakeWebSocketTransport(
            openResult: .failure(WebSocketFixtureError.expected)
        )
        let client = APIClient(
            baseURL: URL(string: "https://example.com"),
            webSocketTransportFactory: { _, _, _ in transport }
        )

        let error = await requireWebSocketError {
            try await client.connect(WebSocketFixtureRequest())
        }
        guard case .unknown(let underlying)? = error else {
            Issue.record(
                "Expected unknown error, got \(String(describing: error))"
            )
            return
        }
        #expect(underlying is WebSocketFixtureError)
        #expect(transport.snapshot.cancelCount == 0)
    }

    @Test("Cancelling connect cancels its transport and preserves cancellation")
    func connectCancellation() async {
        let transport = FakeWebSocketTransport(openResult: nil)
        let client = APIClient(
            baseURL: URL(string: "https://example.com"),
            webSocketTransportFactory: { _, _, _ in transport }
        )
        let task = Task {
            try await client.connect(WebSocketFixtureRequest())
        }

        await transport.openStarted.wait()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(transport.snapshot.cancelCount == 1)
    }

    @Test("Connect snapshots mutable transport options exactly once")
    func connectSnapshotsTransportOptions() async throws {
        let expectedPolicy = WebSocketInboundBufferingPolicy(
            maximumMessages: 7,
            maximumBytes: 4_096
        )
        let request = AlternatingWebSocketTransportOptionsRequest(
            firstMaximumMessageSize: 2_048,
            firstBufferingPolicy: expectedPolicy
        )
        let capturedConfiguration = LockedBox<
            WebSocketTransportConfiguration?
        >(nil)
        let transport = FakeWebSocketTransport()
        let client = APIClient(
            baseURL: URL(string: "https://example.com"),
            webSocketTransportFactory: { _, _, configuration in
                capturedConfiguration.withLock { $0 = configuration }
                return transport
            }
        )

        _ = try await client.connect(request)

        let captured = try #require(capturedConfiguration.withLock { $0 })
        #expect(captured.maximumMessageSize == 2_048)
        #expect(captured.inboundBufferingPolicy == expectedPolicy)
        #expect(request.readCounts.maximumMessageSize == 1)
        #expect(request.readCounts.inboundBufferingPolicy == 1)
    }
}

@Suite("URLSession WebSocket transport")
struct URLSessionWebSocketTransportTests {
    @Test("WebSocket task metrics are forwarded without transport state changes")
    func taskMetricsAreForwarded() {
        let adapter = FakeWebSocketTaskAdapter()
        let transport = URLSessionWebSocketTransport(adapter: adapter)
        let snapshots = LockedBox<[NetworkTaskMetricsSnapshot]>([])
        transport.setTaskMetricsHandler { snapshot in
            snapshots.withLock { $0.append(snapshot) }
        }
        let snapshot = NetworkTaskMetricsSnapshot(
            fetchStart: Date(timeIntervalSince1970: 1),
            responseEnd: Date(timeIntervalSince1970: 2),
            requestDurationNanoseconds: 1_000
        )

        adapter.emit(.metrics(snapshot))

        #expect(snapshots.withLock { $0 } == [snapshot])
        if case .closed = transport.status() {
            Issue.record("Metrics must not close the WebSocket transport")
        }
    }
    @Test("Open returns the negotiated protocol and tracks peer closure")
    func openAndCloseLifecycle() async throws {
        let adapter = FakeWebSocketTaskAdapter(
            eventOnResume: .opened(negotiatedSubprotocol: "chat.v2")
        )
        let transport = URLSessionWebSocketTransport(adapter: adapter)

        #expect(try await transport.open() == "chat.v2")
        #expect(adapter.snapshot.resumeCount == 1)
        guard case .open = transport.status() else {
            Issue.record("Expected an open transport")
            return
        }

        let repeatedOpen = await requireWebSocketError {
            try await transport.open()
        }
        guard case .connectionAlreadyStarted? = repeatedOpen else {
            Issue.record(
                "Expected connectionAlreadyStarted, got \(String(describing: repeatedOpen))"
            )
            return
        }
        #expect(adapter.snapshot.resumeCount == 1)

        let peerClose = WebSocketClose(
            code: .goingAway,
            reason: Data("server restart".utf8)
        )
        adapter.emit(.closed(peerClose))

        guard case .closed(let close) = transport.status() else {
            Issue.record("Expected a closed transport")
            return
        }
        #expect(close == peerClose)
    }

    @Test("Lifecycle states observe an idle peer closing the connection")
    func lifecycleStatesObserveIdlePeerClosure() async throws {
        let url = try #require(URL(string: "wss://example.com/socket"))
        let adapter = FakeWebSocketTaskAdapter(
            eventOnResume: .opened(negotiatedSubprotocol: nil)
        )
        let transport = URLSessionWebSocketTransport(adapter: adapter)
        _ = try await transport.open()
        let connection = WebSocketConnection(
            url: url,
            negotiatedSubprotocol: nil,
            transport: transport
        )
        var iterator = connection.states.makeAsyncIterator()

        #expect(await iterator.next() == .open)

        let peerClose = WebSocketClose(
            code: .goingAway,
            reason: Data("server restart".utf8)
        )
        adapter.emit(.closed(peerClose))

        #expect(await iterator.next() == .closed(peerClose))
        #expect(await iterator.next() == nil)
        #expect(await connection.state == .closed(peerClose))
    }

    @Test("A close snapshot wakes lifecycle observers without a delegate event")
    func lifecycleStatesObserveTaskCloseSnapshot() async throws {
        let url = try #require(URL(string: "wss://example.com/socket"))
        let adapter = FakeWebSocketTaskAdapter(
            eventOnResume: .opened(negotiatedSubprotocol: nil)
        )
        let transport = URLSessionWebSocketTransport(adapter: adapter)
        _ = try await transport.open()
        let connection = WebSocketConnection(
            url: url,
            negotiatedSubprotocol: nil,
            transport: transport
        )
        var iterator = connection.states.makeAsyncIterator()
        #expect(await iterator.next() == .open)

        let peerClose = WebSocketClose(
            code: .serviceRestart,
            reason: Data("rolling restart".utf8)
        )
        adapter.setCloseDetails(peerClose)

        #expect(await connection.state == .closed(peerClose))
        #expect(await iterator.next() == .closed(peerClose))
        #expect(await iterator.next() == nil)
    }

    @Test("Peer closure during the handshake fails open with close details")
    func closedDuringHandshake() async {
        let peerClose = WebSocketClose(
            code: .policyViolation,
            reason: Data("denied".utf8)
        )
        let adapter = FakeWebSocketTaskAdapter(eventOnResume: .closed(peerClose))
        let transport = URLSessionWebSocketTransport(adapter: adapter)

        let error = await requireWebSocketError {
            try await transport.open()
        }
        guard case .connectionClosed(let close)? = error else {
            Issue.record(
                "Expected connectionClosed, got \(String(describing: error))"
            )
            return
        }
        #expect(close == peerClose)

        guard case .closed(let statusClose) = transport.status() else {
            Issue.record("Expected a closed transport")
            return
        }
        #expect(statusClose == peerClose)
    }

    @Test("Task completion errors fail an unfinished handshake")
    func completionFailureDuringHandshake() async {
        let expected = URLError(.cannotConnectToHost)
        let adapter = FakeWebSocketTaskAdapter(
            eventOnResume: .completed(expected)
        )
        let transport = URLSessionWebSocketTransport(adapter: adapter)
        var stateIterator = transport.stateStream().makeAsyncIterator()

        #expect(await stateIterator.next() == .open)

        do {
            _ = try await transport.open()
            Issue.record("Expected the handshake to fail")
        } catch let error as URLError {
            #expect(error.code == expected.code)
        } catch {
            Issue.record("Expected URLError, got \(error)")
        }

        guard case .closed(nil) = transport.status() else {
            Issue.record("Expected a closed transport without peer details")
            return
        }
        #expect(await stateIterator.next() == .closed(nil))
        #expect(await stateIterator.next() == nil)
    }

    @Test("Rejected upgrades preserve HTTP response metadata")
    func rejectedHandshakeMetadata() async throws {
        let url = try #require(URL(string: "wss://example.com/socket"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 401,
            httpVersion: "HTTP/1.1",
            headerFields: ["WWW-Authenticate": "Bearer"]
        ))
        let underlying = URLError(.userAuthenticationRequired)
        let adapter = FakeWebSocketTaskAdapter(
            eventOnResume: .completed(underlying),
            handshakeResponse: response
        )
        let transport = URLSessionWebSocketTransport(adapter: adapter)

        let error = await requireWebSocketError {
            try await transport.open()
        }
        guard case .handshakeFailed(let metadata, let cause)? = error else {
            Issue.record(
                "Expected handshakeFailed, got \(String(describing: error))"
            )
            return
        }
        #expect(metadata.statusCode == 401)
        #expect(metadata.url == url)
        #expect(metadata.value(forHTTPHeaderField: "WWW-Authenticate")
            == "Bearer")
        #expect((cause as? URLError)?.code == underlying.code)
    }

    @Test("Cancelling an unfinished open cancels its task adapter")
    func openCancellation() async {
        let adapter = FakeWebSocketTaskAdapter()
        let transport = URLSessionWebSocketTransport(adapter: adapter)
        let task = Task { try await transport.open() }

        await adapter.resumed.wait()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(adapter.snapshot.cancelCount == 1)

        adapter.emit(.opened(negotiatedSubprotocol: "late"))
        guard case .closed(nil) = transport.status() else {
            Issue.record("Expected cancellation to leave the transport closed")
            return
        }
    }

    @Test("Send, receive, ping, and close delegate to the task adapter")
    func operations() async throws {
        let payload = Data([0x01, 0x02, 0x03])
        let adapter = FakeWebSocketTaskAdapter(
            eventOnResume: .opened(negotiatedSubprotocol: nil),
            sendResult: .success(()),
            receiveResult: .success(.binary(payload)),
            pingResult: .success(())
        )
        let transport = URLSessionWebSocketTransport(adapter: adapter)
        _ = try await transport.open()

        try await transport.send(.text("hello"))
        #expect(try await transport.receive() == .binary(payload))
        try await transport.ping()
        transport.close(
            code: .normalClosure,
            reason: Data("finished".utf8)
        )

        let snapshot = adapter.snapshot
        #expect(snapshot.sentMessages == [.text("hello")])
        #expect(snapshot.receiveCount == 2)
        #expect(snapshot.pingCount == 1)
        #expect(snapshot.closes.count == 1)
        #expect(snapshot.closes.first?.code == .normalClosure)
        #expect(snapshot.closes.first?.reason == Data("finished".utf8))
    }

    @Test("The receive pump starts on open and prefetches FIFO")
    func receivePumpPrefetchesFIFO() async throws {
        let expected: [WebSocketMessage] = [
            .text("first"),
            .binary(Data([0x02, 0x03])),
            .text("third"),
        ]
        let adapter = FakeWebSocketTaskAdapter(
            eventOnResume: .opened(negotiatedSubprotocol: nil),
            receiveResults: expected.map { .success($0) }
        )
        let transport = URLSessionWebSocketTransport(adapter: adapter)

        _ = try await transport.open()
        #expect(adapter.snapshot.receiveCount == expected.count + 1)

        var received: [WebSocketMessage] = []
        for _ in expected {
            received.append(try await transport.receive())
        }
        #expect(received == expected)
        #expect(adapter.snapshot.receiveCount == expected.count + 1)
    }

    @Test("Asynchronous receive callbacks rearm exactly once")
    func asynchronousReceiveCallbacksRearm() async throws {
        let adapter = FakeWebSocketTaskAdapter(
            eventOnResume: .opened(negotiatedSubprotocol: nil)
        )
        let transport = URLSessionWebSocketTransport(adapter: adapter)
        _ = try await transport.open()
        #expect(adapter.snapshot.receiveCount == 1)

        adapter.completeReceive(.success(.text("first")))
        #expect(adapter.snapshot.receiveCount == 2)
        adapter.completeReceive(.success(.text("second")))
        #expect(adapter.snapshot.receiveCount == 3)

        #expect(try await transport.receive() == .text("first"))
        #expect(try await transport.receive() == .text("second"))
        #expect(adapter.snapshot.receiveCount == 3)
    }

    @Test("A waiting receiver gets direct delivery before the pump rearms")
    func pendingReceiverGetsDirectDelivery() async throws {
        let adapter = FakeWebSocketTaskAdapter(
            eventOnResume: .opened(negotiatedSubprotocol: nil)
        )
        let transport = URLSessionWebSocketTransport(
            adapter: adapter,
            inboundBufferingPolicy: .init(
                maximumMessages: 1,
                maximumBytes: 1
            )
        )
        _ = try await transport.open()
        #expect(adapter.snapshot.receiveCount == 1)

        let receiveTask = Task { try await transport.receive() }
        for _ in 0..<1_000 where !transport.hasPendingReceiveForTesting {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(transport.hasPendingReceiveForTesting)
        adapter.completeReceive(.success(.text("direct")))

        #expect(try await receiveTask.value == .text("direct"))
        #expect(adapter.snapshot.receiveCount == 2)
    }

    @Test("Synchronous receive bursts use constant stack depth")
    func synchronousReceiveBurst() async throws {
        let expected = (0..<2_048).map { index in
            WebSocketMessage.binary(Data([UInt8(index & 0xff)]))
        }
        let adapter = FakeWebSocketTaskAdapter(
            eventOnResume: .opened(negotiatedSubprotocol: nil),
            receiveResults: expected.map { .success($0) }
        )
        let transport = URLSessionWebSocketTransport(
            adapter: adapter,
            inboundBufferingPolicy: .init(
                maximumMessages: expected.count,
                maximumBytes: expected.count
            )
        )

        _ = try await transport.open()
        #expect(adapter.snapshot.receiveCount == expected.count + 1)

        var received: [WebSocketMessage] = []
        received.reserveCapacity(expected.count)
        for _ in expected {
            received.append(try await transport.receive())
        }
        #expect(received == expected)
    }

    @Test("Count overflow preserves the accepted prefix and fails closed")
    func inboundMessageCountOverflow() async throws {
        let accepted: [WebSocketMessage] = [
            .text("one"),
            .binary(Data([0x02, 0x03])),
        ]
        let rejected = WebSocketMessage.text("three")
        let adapter = FakeWebSocketTaskAdapter(
            eventOnResume: .opened(negotiatedSubprotocol: nil),
            receiveResults: (accepted + [rejected]).map { .success($0) }
        )
        let policy = WebSocketInboundBufferingPolicy(
            maximumMessages: 2,
            maximumBytes: 1_024
        )
        let transport = URLSessionWebSocketTransport(
            adapter: adapter,
            inboundBufferingPolicy: policy
        )

        _ = try await transport.open()
        guard case .closed(nil) = transport.status() else {
            Issue.record("Expected overflow to close the transport")
            return
        }
        #expect(adapter.snapshot.receiveCount == 3)
        #expect(adapter.snapshot.cancelCount == 1)
        #expect(try await transport.receive() == accepted[0])
        #expect(try await transport.receive() == accepted[1])

        let error = await requireWebSocketError {
            try await transport.receive()
        }
        guard case .inboundBufferOverflow(let overflow)? = error else {
            Issue.record(
                "Expected inboundBufferOverflow, got \(String(describing: error))"
            )
            return
        }
        #expect(overflow.policy == policy)
        #expect(overflow.bufferedMessageCount == 2)
        #expect(overflow.bufferedByteCount == 5)
        #expect(overflow.incomingMessageByteCount == 5)

        let lateClose = WebSocketClose(
            code: .policyViolation,
            reason: Data("slow consumer".utf8)
        )
        adapter.emit(.closed(lateClose))
        guard case .closed(let reportedClose) = transport.status() else {
            Issue.record("Expected late close details to refine status")
            return
        }
        #expect(reportedClose == lateClose)

        let repeatedError = await requireWebSocketError {
            try await transport.receive()
        }
        guard case .inboundBufferOverflow(let repeatedOverflow)? =
            repeatedError else {
            Issue.record("Expected overflow to remain the terminal result")
            return
        }
        #expect(repeatedOverflow == overflow)
        #expect(adapter.snapshot.cancelCount == 1)
    }

    @Test("Byte overflow counts UTF-8 and binary payloads exactly")
    func inboundByteOverflow() async throws {
        let accepted: [WebSocketMessage] = [
            .text("é"),
            .binary(Data([0x01, 0x02, 0x03])),
        ]
        let adapter = FakeWebSocketTaskAdapter(
            eventOnResume: .opened(negotiatedSubprotocol: nil),
            receiveResults: (accepted + [.text("!")]).map { .success($0) }
        )
        let policy = WebSocketInboundBufferingPolicy(
            maximumMessages: 4,
            maximumBytes: 5
        )
        let transport = URLSessionWebSocketTransport(
            adapter: adapter,
            inboundBufferingPolicy: policy
        )

        _ = try await transport.open()
        #expect(try await transport.receive() == accepted[0])
        #expect(try await transport.receive() == accepted[1])

        let error = await requireWebSocketError {
            try await transport.receive()
        }
        guard case .inboundBufferOverflow(let overflow)? = error else {
            Issue.record(
                "Expected inboundBufferOverflow, got \(String(describing: error))"
            )
            return
        }
        #expect(overflow.bufferedMessageCount == 2)
        #expect(overflow.bufferedByteCount == 5)
        #expect(overflow.incomingMessageByteCount == 1)
        #expect(adapter.snapshot.cancelCount == 1)
    }

    @Test("Buffered messages drain before peer closure is surfaced")
    func bufferedMessagesDrainBeforePeerClose() async throws {
        let messages: [WebSocketMessage] = [
            .text("before-close"),
            .binary(Data([0xca, 0xfe])),
        ]
        let adapter = FakeWebSocketTaskAdapter(
            eventOnResume: .opened(negotiatedSubprotocol: nil),
            receiveResults: messages.map { .success($0) }
        )
        let transport = URLSessionWebSocketTransport(adapter: adapter)
        _ = try await transport.open()
        let connection = WebSocketConnection(
            url: try #require(URL(string: "wss://example.com/socket")),
            negotiatedSubprotocol: nil,
            transport: transport
        )
        let close = WebSocketClose(
            code: .goingAway,
            reason: Data("maintenance".utf8)
        )

        adapter.emit(.closed(close))

        #expect(await connection.state == .closed(close))
        var iterator = connection.messages.makeAsyncIterator()
        #expect(try await iterator.next() == messages[0])
        #expect(try await iterator.next() == messages[1])
        #expect(try await iterator.next() == nil)
        #expect(adapter.snapshot.cancelCount == 0)

        adapter.completeReceive(.success(.text("late")))
        #expect(adapter.snapshot.receiveCount == messages.count + 1)
    }

    @Test("Receive failures wait for peer close details without hard cancel")
    func receiveFailureWaitsForCloseDetails() async throws {
        for locallyInitiated in [false, true] {
            let adapter = FakeWebSocketTaskAdapter(
                eventOnResume: .opened(negotiatedSubprotocol: nil)
            )
            let transport = URLSessionWebSocketTransport(adapter: adapter)
            _ = try await transport.open()
            let receiveTask = Task { try await transport.receive() }
            await Task.yield()

            if locallyInitiated {
                transport.close(
                    code: .normalClosure,
                    reason: Data("done".utf8)
                )
            }
            adapter.completeReceive(.failure(URLError(.cancelled)))

            #expect(adapter.snapshot.cancelCount == 0)
            #expect(adapter.snapshot.closes.count == (locallyInitiated ? 1 : 0))

            let close = WebSocketClose(
                code: locallyInitiated ? .normalClosure : .goingAway,
                reason: Data("peer close".utf8)
            )
            adapter.setCloseDetails(close)
            adapter.emit(.closed(close))

            let error = await requireWebSocketError {
                try await receiveTask.value
            }
            guard case .connectionClosed(let reportedClose)? = error else {
                Issue.record("Expected refined connectionClosed error")
                continue
            }
            #expect(reportedClose == close)
            #expect(adapter.snapshot.cancelCount == 0)
        }
    }

    @Test("Operation failures close the transport")
    func operationFailure() async throws {
        let expected = URLError(.networkConnectionLost)
        let adapter = FakeWebSocketTaskAdapter(
            eventOnResume: .opened(negotiatedSubprotocol: nil),
            sendResult: .failure(expected)
        )
        let transport = URLSessionWebSocketTransport(adapter: adapter)
        _ = try await transport.open()

        do {
            try await transport.send(.text("hello"))
            Issue.record("Expected send to fail")
        } catch let error as URLError {
            #expect(error.code == expected.code)
        } catch {
            Issue.record("Expected URLError, got \(error)")
        }

        guard case .closed(nil) = transport.status() else {
            Issue.record("Expected a failed operation to close the transport")
            return
        }
        #expect(adapter.snapshot.cancelCount == 1)
    }

    @Test("Cancelling a pending operation cancels its task adapter")
    func operationCancellation() async throws {
        let adapter = FakeWebSocketTaskAdapter(
            eventOnResume: .opened(negotiatedSubprotocol: nil)
        )
        let transport = URLSessionWebSocketTransport(adapter: adapter)
        _ = try await transport.open()

        let task = Task { try await transport.receive() }
        await adapter.receiveStarted.wait()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(adapter.snapshot.cancelCount == 1)

        adapter.completeReceive(.success(.text("late")))
        guard case .closed(nil) = transport.status() else {
            Issue.record("Expected cancellation to close the transport")
            return
        }
    }
}

@Suite("WebSocket connection")
struct WebSocketConnectionTests {
    @Test("Connection operations preserve metadata and delegate messages")
    func operationsAndMetadata() async throws {
        let url = try #require(URL(string: "wss://example.com/socket"))
        let transport = FakeWebSocketTransport(receiveResults: [
            .success(.text("first")),
            .success(.binary(Data([0xCA, 0xFE])))
        ])
        let connection = WebSocketConnection(
            url: url,
            negotiatedSubprotocol: "chat.v2",
            transport: transport
        )

        #expect(connection.url == url)
        #expect(connection.negotiatedSubprotocol == "chat.v2")
        #expect(await connection.state == .open)

        try await connection.send(text: "hello")
        try await connection.send(data: Data([0x01]))
        #expect(try await connection.receive() == .text("first"))
        #expect(try await connection.receive() == .binary(Data([0xCA, 0xFE])))
        try await connection.ping()

        let snapshot = transport.snapshot
        #expect(snapshot.sentMessages == [
            .text("hello"),
            .binary(Data([0x01]))
        ])
        #expect(snapshot.receiveCount == 2)
        #expect(snapshot.pingCount == 1)
        #expect(await connection.state == .open)
    }

    @Test("Message sequence performs one receive for each next call")
    func messageSequence() async throws {
        let transport = FakeWebSocketTransport(receiveResults: [
            .success(.text("one")),
            .success(.text("two"))
        ])
        let connection = WebSocketConnection(
            url: URL(string: "wss://example.com/socket")!,
            negotiatedSubprotocol: nil,
            transport: transport
        )
        var iterator = connection.messages.makeAsyncIterator()

        #expect(try await iterator.next() == .text("one"))
        #expect(transport.snapshot.receiveCount == 1)
        #expect(try await iterator.next() == .text("two"))
        #expect(transport.snapshot.receiveCount == 2)
    }

    @Test("Clean peer closures end message sequences normally")
    func cleanSequenceTermination() async throws {
        for code in [WebSocketCloseCode.normalClosure, .goingAway] {
            let close = WebSocketClose(code: code)
            let transport = FakeWebSocketTransport(receiveResults: [
                .failure(WebSocketError.connectionClosed(close))
            ])
            let connection = WebSocketConnection(
                url: URL(string: "wss://example.com/socket")!,
                negotiatedSubprotocol: nil,
                transport: transport
            )
            var iterator = connection.messages.makeAsyncIterator()

            #expect(try await iterator.next() == nil)
            #expect(await connection.state == .closed(close))
        }
    }

    @Test("Abnormal peer closures remain sequence errors")
    func abnormalSequenceTermination() async {
        let close = WebSocketClose(code: .policyViolation)
        let transport = FakeWebSocketTransport(receiveResults: [
            .failure(WebSocketError.connectionClosed(close))
        ])
        let connection = WebSocketConnection(
            url: URL(string: "wss://example.com/socket")!,
            negotiatedSubprotocol: nil,
            transport: transport
        )
        var iterator = connection.messages.makeAsyncIterator()

        let error = await requireWebSocketError {
            try await iterator.next()
        }
        guard case .connectionClosed(let reportedClose)? = error else {
            Issue.record("Expected connectionClosed")
            return
        }
        #expect(reportedClose == close)
    }

    @Test("A second receive is rejected while the first is pending")
    func concurrentReceive() async throws {
        let transport = FakeWebSocketTransport()
        let connection = WebSocketConnection(
            url: URL(string: "wss://example.com/socket")!,
            negotiatedSubprotocol: nil,
            transport: transport
        )
        let first = Task { try await connection.receive() }

        await transport.receiveStarted.wait()
        let error = await requireWebSocketError {
            try await connection.receive()
        }
        guard case .concurrentReceive? = error else {
            Issue.record(
                "Expected concurrentReceive, got \(String(describing: error))"
            )
            transport.completeReceive(.success(.text("first")))
            _ = try? await first.value
            return
        }

        transport.completeReceive(.success(.text("first")))
        #expect(try await first.value == .text("first"))
        #expect(transport.snapshot.receiveCount == 1)
    }

    @Test("Close validates payloads, becomes idempotent, and tracks peer closure")
    func closeAndState() async throws {
        let transport = FakeWebSocketTransport()
        let connection = WebSocketConnection(
            url: URL(string: "wss://example.com/socket")!,
            negotiatedSubprotocol: nil,
            transport: transport
        )

        for code in [999, 1_005, 1_015, 1_016, 5_000] {
            let error = await requireWebSocketError {
                try await connection.close(
                    code: WebSocketCloseCode(rawValue: code),
                    reason: nil
                )
            }
            guard case .invalidCloseCode(let actual)? = error else {
                Issue.record(
                    "Expected invalidCloseCode, got \(String(describing: error))"
                )
                continue
            }
            #expect(actual == code)
        }

        let oversizedReason = String(repeating: "💥", count: 31)
        let reasonError = await requireWebSocketError {
            try await connection.close(
                code: .normalClosure,
                reason: oversizedReason
            )
        }
        guard case .closeReasonTooLong(
            let maximumBytes,
            let actualBytes
        )? = reasonError else {
            Issue.record(
                "Expected closeReasonTooLong, got \(String(describing: reasonError))"
            )
            return
        }
        #expect(maximumBytes == 123)
        #expect(actualBytes == 124)
        #expect(transport.snapshot.closes.isEmpty)

        let validReason = String(repeating: "é", count: 61) + "a"
        let applicationCode = WebSocketCloseCode(rawValue: 4_000)
        try await connection.close(code: applicationCode, reason: validReason)

        #expect(await connection.state == .closing)
        #expect(transport.snapshot.closes.count == 1)
        #expect(transport.snapshot.closes.first?.code == applicationCode)
        #expect(transport.snapshot.closes.first?.reason
            == Data(validReason.utf8))

        try await connection.close(code: .normalClosure, reason: nil)
        #expect(transport.snapshot.closes.count == 1)

        let closingError = await requireWebSocketError {
            try await connection.send(text: "too late")
        }
        guard case .connectionClosing? = closingError else {
            Issue.record(
                "Expected connectionClosing, got \(String(describing: closingError))"
            )
            return
        }

        let peerClose = WebSocketClose(
            code: .normalClosure,
            reason: Data("done".utf8)
        )
        transport.setStatus(.closed(peerClose))
        #expect(await connection.state == .closed(peerClose))

        let closedError = await requireWebSocketError {
            try await connection.ping()
        }
        guard case .connectionClosed(let close)? = closedError else {
            Issue.record(
                "Expected connectionClosed, got \(String(describing: closedError))"
            )
            return
        }
        #expect(close == peerClose)
    }

    @Test("Assigned standard and application close codes are accepted")
    func acceptedCloseCodes() async throws {
        let acceptedCodes = [1_012, 1_013, 1_014, 3_000, 4_999]

        for rawValue in acceptedCodes {
            let transport = FakeWebSocketTransport()
            let connection = WebSocketConnection(
                url: URL(string: "wss://example.com/socket")!,
                negotiatedSubprotocol: nil,
                transport: transport
            )

            try await connection.close(
                code: WebSocketCloseCode(rawValue: rawValue),
                reason: nil
            )

            #expect(transport.snapshot.closes.count == 1)
            #expect(transport.snapshot.closes.first?.code.rawValue == rawValue)
        }
    }

    @Test("Callback failure uses task close details before a delegate event")
    func callbackFailureUsesTaskCloseDetails() async throws {
        let peerClose = WebSocketClose(
            code: .serviceRestart,
            reason: Data("rolling restart".utf8)
        )
        let adapter = FakeWebSocketTaskAdapter(
            eventOnResume: .opened(negotiatedSubprotocol: nil)
        )
        let transport = URLSessionWebSocketTransport(adapter: adapter)
        _ = try await transport.open()
        let connection = WebSocketConnection(
            url: URL(string: "wss://example.com/socket")!,
            negotiatedSubprotocol: nil,
            transport: transport
        )
        let sendTask = Task { try await connection.send(text: "hello") }

        await adapter.sendStarted.wait()
        adapter.setCloseDetails(peerClose)
        adapter.completeSend(.failure(URLError(.networkConnectionLost)))

        do {
            try await sendTask.value
            Issue.record("Expected peer closure")
        } catch let error as WebSocketError {
            guard case .connectionClosed(let close) = error else {
                Issue.record("Expected connectionClosed, got \(error)")
                return
            }
            #expect(close == peerClose)
        } catch {
            Issue.record("Expected WebSocketError, got \(error)")
        }

        #expect(adapter.snapshot.closeDetails == peerClose)
        #expect(await connection.state == .closed(peerClose))
    }

    @Test("Cancellation wins at both successful and failed completion boundaries")
    func cancellationPrecedenceAtCompletion() async throws {
        let results: [Result<Void, any Error>] = [
            .success(()),
            .failure(URLError(.networkConnectionLost))
        ]

        for result in results {
            let adapter = FakeWebSocketTaskAdapter(
                eventOnResume: .opened(negotiatedSubprotocol: nil),
                sendResult: result,
                cancelCurrentTaskAfterSendCompletion: true
            )
            let transport = URLSessionWebSocketTransport(adapter: adapter)
            _ = try await transport.open()
            let connection = WebSocketConnection(
                url: URL(string: "wss://example.com/socket")!,
                negotiatedSubprotocol: nil,
                transport: transport
            )
            let task = Task { try await connection.send(text: "hello") }

            do {
                try await task.value
                Issue.record("Expected cancellation")
            } catch {
                #expect(error is CancellationError)
            }

            #expect(await connection.state == .closed(nil))
            #expect(adapter.snapshot.cancelCount <= 1)
        }
    }

    @Test("Transport failures are mapped and close the connection")
    func transportFailure() async {
        let expected = URLError(.networkConnectionLost)
        let transport = FakeWebSocketTransport(
            sendResults: [.failure(expected)]
        )
        let connection = WebSocketConnection(
            url: URL(string: "wss://example.com/socket")!,
            negotiatedSubprotocol: nil,
            transport: transport
        )

        let error = await requireWebSocketError {
            try await connection.send(text: "hello")
        }
        guard case .transport(let underlying)? = error else {
            Issue.record(
                "Expected transport error, got \(String(describing: error))"
            )
            return
        }
        #expect(underlying.code == expected.code)
        #expect(await connection.state == .closed(nil))

        let closedError = await requireWebSocketError {
            try await connection.ping()
        }
        guard case .connectionClosed(let close)? = closedError else {
            Issue.record(
                "Expected connectionClosed, got \(String(describing: closedError))"
            )
            return
        }
        #expect(close == nil)
        #expect(transport.snapshot.pingCount == 0)
    }
}

private struct WebSocketFixtureRequest: WebSocketRequest {
    let path: String
    let pathEncoding: RequestPathEncoding
    let queryItems: [URLQueryItem]?
    let headers: [String: String]?
    let subprotocols: [String]
    let maximumMessageSize: Int?
    let inboundBufferingPolicy: WebSocketInboundBufferingPolicy
    let customization: WebSocketRequestCustomization

    init(
        path: String = "socket",
        pathEncoding: RequestPathEncoding = .decoded,
        queryItems: [URLQueryItem]? = nil,
        headers: [String: String]? = nil,
        subprotocols: [String] = [],
        maximumMessageSize: Int? = nil,
        inboundBufferingPolicy: WebSocketInboundBufferingPolicy = .default,
        customization: WebSocketRequestCustomization = .none
    ) {
        self.path = path
        self.pathEncoding = pathEncoding
        self.queryItems = queryItems
        self.headers = headers
        self.subprotocols = subprotocols
        self.maximumMessageSize = maximumMessageSize
        self.inboundBufferingPolicy = inboundBufferingPolicy
        self.customization = customization
    }

    func customize(_ urlRequest: inout URLRequest) throws {
        switch customization {
        case .none:
            return
        case .valid:
            urlRequest.timeoutInterval = 17
            urlRequest.setValue(
                "custom-value",
                forHTTPHeaderField: "X-Custom"
            )
        case .method(let method):
            urlRequest.httpMethod = method
        case .body(let data):
            urlRequest.httpBody = data
        case .header(let name, let value):
            urlRequest.setValue(value, forHTTPHeaderField: name)
        case .url(let url):
            urlRequest.url = url
        case .fail:
            throw WebSocketFixtureError.expected
        case .cancel:
            throw CancellationError()
        }
    }
}

private final class AlternatingWebSocketTransportOptionsRequest:
    WebSocketRequest,
    @unchecked Sendable {
    struct ReadCounts: Sendable {
        let maximumMessageSize: Int
        let inboundBufferingPolicy: Int
    }

    private struct State {
        var maximumMessageSizeReads = 0
        var inboundBufferingPolicyReads = 0
    }

    let path = "socket"
    private let firstMaximumMessageSize: Int
    private let firstBufferingPolicy: WebSocketInboundBufferingPolicy
    private let state = LockedBox(State())

    init(
        firstMaximumMessageSize: Int,
        firstBufferingPolicy: WebSocketInboundBufferingPolicy
    ) {
        self.firstMaximumMessageSize = firstMaximumMessageSize
        self.firstBufferingPolicy = firstBufferingPolicy
    }

    var maximumMessageSize: Int? {
        state.withLock { state in
            state.maximumMessageSizeReads += 1
            return state.maximumMessageSizeReads == 1
                ? firstMaximumMessageSize
                : 0
        }
    }

    var inboundBufferingPolicy: WebSocketInboundBufferingPolicy {
        state.withLock { state in
            state.inboundBufferingPolicyReads += 1
            return state.inboundBufferingPolicyReads == 1
                ? firstBufferingPolicy
                : WebSocketInboundBufferingPolicy(
                    maximumMessages: 0,
                    maximumBytes: 0
                )
        }
    }

    var readCounts: ReadCounts {
        state.withLock { state in
            ReadCounts(
                maximumMessageSize: state.maximumMessageSizeReads,
                inboundBufferingPolicy: state.inboundBufferingPolicyReads
            )
        }
    }
}

private enum WebSocketRequestCustomization: Sendable {
    case none
    case valid
    case method(String)
    case body(Data)
    case header(String, String)
    case url(URL)
    case fail
    case cancel
}

private enum WebSocketFixtureError: Error, Sendable {
    case expected
}

private struct CapturedWebSocketFactoryInput {
    let session: URLSession
    let request: URLRequest
    let configuration: WebSocketTransportConfiguration
}

private func requireWebSocketError<Success>(
    _ operation: () throws -> Success
) -> WebSocketError? {
    do {
        _ = try operation()
        Issue.record("Expected a WebSocketError")
        return nil
    } catch let error as WebSocketError {
        return error
    } catch {
        Issue.record("Expected WebSocketError, got \(error)")
        return nil
    }
}

private func requireWebSocketError<Success>(
    _ operation: () async throws -> Success
) async -> WebSocketError? {
    do {
        _ = try await operation()
        Issue.record("Expected a WebSocketError")
        return nil
    } catch let error as WebSocketError {
        return error
    } catch {
        Issue.record("Expected WebSocketError, got \(error)")
        return nil
    }
}

private final class FakeWebSocketTaskAdapter: WebSocketTaskAdapter,
    @unchecked Sendable {
    typealias EventHandler = @Sendable (WebSocketTaskEvent) -> Void
    typealias VoidCompletion = @Sendable (
        Result<Void, any Error>
    ) -> Void
    typealias ReceiveCompletion = @Sendable (
        Result<WebSocketMessage, any Error>
    ) -> Void

    struct CloseRecord: Sendable {
        let code: WebSocketCloseCode
        let reason: Data?
    }

    struct Snapshot: Sendable {
        let resumeCount: Int
        let cancelCount: Int
        let sentMessages: [WebSocketMessage]
        let receiveCount: Int
        let pingCount: Int
        let closes: [CloseRecord]
        let closeDetails: WebSocketClose?
    }

    private struct State {
        var eventHandler: EventHandler?
        var eventOnResume: WebSocketTaskEvent?
        var sendResult: Result<Void, any Error>?
        var receiveResults: [Result<WebSocketMessage, any Error>]
        var nextReceiveResultIndex = 0
        var pingResult: Result<Void, any Error>?
        var sendCompletion: VoidCompletion?
        var receiveCompletion: ReceiveCompletion?
        var pingCompletion: VoidCompletion?
        var closeDetails: WebSocketClose?
        var handshakeResponse: HTTPURLResponse?
        var cancelCurrentTaskAfterSendCompletion: Bool
        var resumeCount = 0
        var cancelCount = 0
        var sentMessages: [WebSocketMessage] = []
        var receiveCount = 0
        var pingCount = 0
        var closes: [CloseRecord] = []
    }

    let resumed = AsyncSignal()
    let sendStarted = AsyncSignal()
    let receiveStarted = AsyncSignal()

    private let state: LockedBox<State>

    init(
        eventOnResume: WebSocketTaskEvent? = nil,
        sendResult: Result<Void, any Error>? = nil,
        receiveResult: Result<WebSocketMessage, any Error>? = nil,
        receiveResults: [Result<WebSocketMessage, any Error>] = [],
        pingResult: Result<Void, any Error>? = nil,
        handshakeResponse: HTTPURLResponse? = nil,
        cancelCurrentTaskAfterSendCompletion: Bool = false
    ) {
        var configuredReceiveResults = receiveResults
        if let receiveResult {
            configuredReceiveResults.insert(receiveResult, at: 0)
        }
        state = LockedBox(State(
            eventOnResume: eventOnResume,
            sendResult: sendResult,
            receiveResults: configuredReceiveResults,
            pingResult: pingResult,
            handshakeResponse: handshakeResponse,
            cancelCurrentTaskAfterSendCompletion:
                cancelCurrentTaskAfterSendCompletion
        ))
    }

    var snapshot: Snapshot {
        state.withLock { state in
            Snapshot(
                resumeCount: state.resumeCount,
                cancelCount: state.cancelCount,
                sentMessages: state.sentMessages,
                receiveCount: state.receiveCount,
                pingCount: state.pingCount,
                closes: state.closes,
                closeDetails: state.closeDetails
            )
        }
    }

    func setEventHandler(_ handler: @escaping EventHandler) {
        state.withLock { $0.eventHandler = handler }
    }

    func resume() {
        let event = state.withLock { state in
            state.resumeCount += 1
            return state.eventOnResume
        }
        Task { await resumed.signal() }
        if let event {
            emit(event)
        }
    }

    func send(
        _ message: WebSocketMessage,
        completion: @escaping VoidCompletion
    ) {
        let (result, shouldCancelTask) = state.withLock { state in
            state.sentMessages.append(message)
            if state.sendResult == nil {
                state.sendCompletion = completion
            }
            return (
                state.sendResult,
                state.cancelCurrentTaskAfterSendCompletion
            )
        }
        Task { await sendStarted.signal() }
        if let result {
            completion(result)
            if shouldCancelTask {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
    }

    func receive(completion: @escaping ReceiveCompletion) {
        let result = state.withLock {
            state -> Result<WebSocketMessage, any Error>? in
            state.receiveCount += 1
            if state.nextReceiveResultIndex < state.receiveResults.count {
                let result = state.receiveResults[state.nextReceiveResultIndex]
                state.nextReceiveResultIndex += 1
                return result
            } else {
                state.receiveCompletion = completion
                return nil
            }
        }
        Task { await receiveStarted.signal() }
        if let result {
            completion(result)
        }
    }

    func ping(completion: @escaping VoidCompletion) {
        let result = state.withLock { state in
            state.pingCount += 1
            if state.pingResult == nil {
                state.pingCompletion = completion
            }
            return state.pingResult
        }
        if let result {
            completion(result)
        }
    }

    func close(code: WebSocketCloseCode, reason: Data?) {
        state.withLock {
            $0.closes.append(CloseRecord(code: code, reason: reason))
        }
    }

    func cancel() {
        state.withLock { $0.cancelCount += 1 }
    }

    func closeDetails() -> WebSocketClose? {
        state.withLock { $0.closeDetails }
    }

    func handshakeResponse() -> HTTPURLResponse? {
        state.withLock { $0.handshakeResponse }
    }

    func emit(_ event: WebSocketTaskEvent) {
        let handler = state.withLock { $0.eventHandler }
        handler?(event)
    }

    func setCloseDetails(_ close: WebSocketClose?) {
        state.withLock { $0.closeDetails = close }
    }

    func completeSend(_ result: Result<Void, any Error>) {
        let completion = state.withLock { state in
            defer { state.sendCompletion = nil }
            return state.sendCompletion
        }
        guard let completion else {
            Issue.record("No send callback was pending")
            return
        }
        completion(result)
    }

    func completeReceive(
        _ result: Result<WebSocketMessage, any Error>
    ) {
        let completion = state.withLock { state in
            defer { state.receiveCompletion = nil }
            return state.receiveCompletion
        }
        guard let completion else {
            Issue.record("No receive callback was pending")
            return
        }
        completion(result)
    }
}

private final class FakeWebSocketTransport: WebSocketTransport,
    WebSocketTaskMetricsReporting,
    @unchecked Sendable {
    struct CloseRecord: Sendable {
        let code: WebSocketCloseCode
        let reason: Data?
    }

    struct Snapshot: Sendable {
        let openCount: Int
        let sentMessages: [WebSocketMessage]
        let receiveCount: Int
        let pingCount: Int
        let closes: [CloseRecord]
        let cancelCount: Int
    }

    private struct State {
        var status: WebSocketTransportStatus
        var openResult: Result<String?, any Error>?
        var sendResults: [Result<Void, any Error>]
        var receiveResults: [Result<WebSocketMessage, any Error>]
        var pingResults: [Result<Void, any Error>]
        var pendingOpen: CheckedContinuation<String?, any Error>?
        var pendingReceive: CheckedContinuation<
            WebSocketMessage,
            any Error
        >?
        var openWasCancelled = false
        var openCount = 0
        var sentMessages: [WebSocketMessage] = []
        var receiveCount = 0
        var pingCount = 0
        var closes: [CloseRecord] = []
        var cancelCount = 0
        var taskMetricsHandler: (
            @Sendable (NetworkTaskMetricsSnapshot) -> Void
        )?
    }

    let openStarted = AsyncSignal()
    let receiveStarted = AsyncSignal()

    private let state: LockedBox<State>

    init(
        status: WebSocketTransportStatus = .open,
        openResult: Result<String?, any Error>? = .success(nil),
        sendResults: [Result<Void, any Error>] = [],
        receiveResults: [Result<WebSocketMessage, any Error>] = [],
        pingResults: [Result<Void, any Error>] = []
    ) {
        state = LockedBox(State(
            status: status,
            openResult: openResult,
            sendResults: sendResults,
            receiveResults: receiveResults,
            pingResults: pingResults,
            taskMetricsHandler: nil
        ))
    }

    var snapshot: Snapshot {
        state.withLock { state in
            Snapshot(
                openCount: state.openCount,
                sentMessages: state.sentMessages,
                receiveCount: state.receiveCount,
                pingCount: state.pingCount,
                closes: state.closes,
                cancelCount: state.cancelCount
            )
        }
    }

    func open() async throws -> String? {
        let result = state.withLock { state in
            state.openCount += 1
            return state.openResult
        }
        if let result {
            return try result.get()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let wasCancelled = state.withLock { state in
                    if state.openWasCancelled || Task.isCancelled {
                        return true
                    }
                    state.pendingOpen = continuation
                    return false
                }
                if wasCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    Task { await self.openStarted.signal() }
                }
            }
        } onCancel: {
            self.cancelPendingOpen()
        }
    }

    func send(_ message: WebSocketMessage) async throws {
        let result = state.withLock { state in
            state.sentMessages.append(message)
            return state.sendResults.isEmpty
                ? Result<Void, any Error>.success(())
                : state.sendResults.removeFirst()
        }
        try result.get()
    }

    func receive() async throws -> WebSocketMessage {
        let result = state.withLock { state -> Result<
            WebSocketMessage,
            any Error
        >? in
            state.receiveCount += 1
            return state.receiveResults.isEmpty
                ? nil
                : state.receiveResults.removeFirst()
        }
        if let result {
            return try result.get()
        }

        return try await withCheckedThrowingContinuation { continuation in
            state.withLock { $0.pendingReceive = continuation }
            Task { await self.receiveStarted.signal() }
        }
    }

    func ping() async throws {
        let result = state.withLock { state in
            state.pingCount += 1
            return state.pingResults.isEmpty
                ? Result<Void, any Error>.success(())
                : state.pingResults.removeFirst()
        }
        try result.get()
    }

    func close(code: WebSocketCloseCode, reason: Data?) {
        state.withLock {
            $0.closes.append(CloseRecord(code: code, reason: reason))
        }
    }

    func cancel() {
        state.withLock { $0.cancelCount += 1 }
    }

    func status() -> WebSocketTransportStatus {
        state.withLock { $0.status }
    }

    func setTaskMetricsHandler(
        _ handler: @escaping @Sendable (NetworkTaskMetricsSnapshot) -> Void
    ) {
        state.withLock { $0.taskMetricsHandler = handler }
    }

    func emitTaskMetrics(_ snapshot: NetworkTaskMetricsSnapshot) {
        let handler = state.withLock { $0.taskMetricsHandler }
        handler?(snapshot)
    }

    func setStatus(_ status: WebSocketTransportStatus) {
        state.withLock { $0.status = status }
    }

    func completeOpen(_ result: Result<String?, any Error>) {
        let continuation = state.withLock { state in
            defer { state.pendingOpen = nil }
            return state.pendingOpen
        }
        guard let continuation else {
            Issue.record("No transport open was pending")
            return
        }
        continuation.resume(with: result)
    }

    func completeReceive(
        _ result: Result<WebSocketMessage, any Error>
    ) {
        let continuation = state.withLock { state in
            defer { state.pendingReceive = nil }
            return state.pendingReceive
        }
        guard let continuation else {
            Issue.record("No transport receive was pending")
            return
        }
        continuation.resume(with: result)
    }

    private func cancelPendingOpen() {
        let continuation = state.withLock { state in
            state.openWasCancelled = true
            defer { state.pendingOpen = nil }
            return state.pendingOpen
        }
        continuation?.resume(throwing: CancellationError())
    }
}
