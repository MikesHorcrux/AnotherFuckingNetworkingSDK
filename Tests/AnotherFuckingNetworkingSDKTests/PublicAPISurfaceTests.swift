import Foundation
import Testing
import AnotherFuckingNetworkingSDK

@Suite("Public API surface")
struct PublicAPISurfaceTests {
    @Test("Standard methods expose stable wire values")
    func methods() {
        #expect(HTTPMethod.allCases.map(\.rawValue) == [
            "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"
        ])
    }

    @Test("HTTP status policies are normalized immutable values")
    func httpStatusPolicies() {
        let custom = HTTPStatusPolicy(
            304...304,
            200...249,
            250...299,
            409...409
        )
        let normalized = HTTPStatusPolicy(ranges: [
            200...299,
            304...304,
            409...409
        ])
        let exact = HTTPStatusPolicy.codes([201, 204, 304])

        requireSendable(custom)
        #expect(custom == normalized)
        #expect(custom.accepts(200))
        #expect(custom.accepts(299))
        #expect(custom.accepts(304))
        #expect(custom.accepts(409))
        #expect(!custom.accepts(199))
        #expect(!custom.accepts(300))
        #expect(!custom.accepts(410))

        #expect(HTTPStatusPolicy.successful.accepts(200))
        #expect(HTTPStatusPolicy.successful.accepts(299))
        #expect(!HTTPStatusPolicy.successful.accepts(199))
        #expect(!HTTPStatusPolicy.successful.accepts(300))
        #expect(HTTPStatusPolicy.all.accepts(Int.min))
        #expect(HTTPStatusPolicy.all.accepts(Int.max))
        #expect(!HTTPStatusPolicy.none.accepts(200))
        #expect(exact.accepts(201))
        #expect(exact.accepts(204))
        #expect(exact.accepts(304))
        #expect(!exact.accepts(202))
        #expect(HTTPStatusPolicy(200...299) == .successful)
        #expect(HTTPStatusPolicy(Int.min...Int.max) == .all)
        #expect(HTTPStatusPolicy() == .none)
    }

    @Test("Every network error has a useful localized description")
    func localizedErrors() {
        let underlying = NSError(
            domain: "Fixture",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "fixture detail"]
        )
        let cases: [(NetworkError, String)] = [
            (.invalidURL, "URL"),
            (.invalidResponse, "non-HTTP"),
            (.encodingFailed(underlying), "fixture detail"),
            (.requestConfigurationFailed(underlying), "fixture detail"),
            (.transport(URLError(.timedOut)), "response"),
            (.requestFailed(HTTPFailure(
                metadata: HTTPResponseMetadata(statusCode: 429)
            )), "429"),
            (.emptyResponse(statusCode: 204), "204"),
            (.decodingFailed(underlying), "fixture detail"),
            (.fileOperationFailed(underlying), "fixture detail"),
            (.unknown(underlying), "fixture detail")
        ]

        for (error, expectedText) in cases {
            #expect(error.localizedDescription.contains(expectedText))
        }
    }

    @Test("HTTP failures expose stable Sendable response details")
    func httpFailureDetails() {
        let body = Data("rate limited".utf8)
        let finalURL = URL(string: "https://api.example.com/v2/users")!
        let failure = HTTPFailure(
            metadata: HTTPResponseMetadata(
                statusCode: 429,
                url: finalURL,
                headers: [
                    "Retry-After": "15",
                    "X-Request-ID": "request-1"
                ]
            ),
            data: body
        )

        requireSendable(failure)
        #expect(failure.statusCode == 429)
        #expect(failure.url == finalURL)
        #expect(failure.headers == [
            "retry-after": "15",
            "x-request-id": "request-1"
        ])
        #expect(failure.value(forHTTPHeaderField: "RETRY-AFTER") == "15")
        #expect(failure.data == body)
        #expect(failure == HTTPFailure(metadata: failure.metadata, data: body))
    }

    @Test("Direct and aggregate configuration APIs stay coherent")
    func configuration() {
        let client = APIClient()
        let baseURL = URL(string: "https://api.example.com")!

        client.baseURL = baseURL
        client.globalHeaders = ["Accept": "application/json"]

        #expect(client.configuration.baseURL == baseURL)
        #expect(client.configuration.globalHeaders == [
            "Accept": "application/json"
        ])

        let defaults = APIClient.Configuration()
        #expect(defaults.baseURL == nil)
        #expect(defaults.globalHeaders.isEmpty)
        let encoded = try? defaults.encoderFactory().encode(["value": 1])
        let decoded = encoded.flatMap {
            try? defaults.decoderFactory().decode([String: Int].self, from: $0)
        }
        #expect(decoded == ["value": 1])
    }

    @Test("Activity monitoring remains Sendable and opt-in")
    func activityMonitoring() async throws {
        let monitor = NetworkActivityMonitor()
        requireSendable(monitor)
        requireSendable(monitor.currentSnapshot)

        let value = try await monitor.track(.request) { "value" }

        #expect(value == "value")
        #expect(monitor.currentSnapshot.succeededCount == 1)
    }

    @available(iOS 17.0, macOS 14.0, *)
    @MainActor
    @Test("The Observation adapter is publicly constructible")
    func observationAdapter() {
        let observable = ObservableNetworkActivity(
            monitor: NetworkActivityMonitor()
        )
        #expect(observable.totalActiveCount == 0)
        observable.stop()
    }

    @Test("Custom WebSocket conformers retain a lifecycle snapshot fallback")
    func customWebSocketStateFallback() async {
        let connection: any WebSocketConnectionProtocol =
            SnapshotOnlyWebSocketConnection()
        requireSendable(connection.states)
        var iterator = connection.states.makeAsyncIterator()

        #expect(await iterator.next() == .closing)
        #expect(await iterator.next() == nil)
    }

    @Test("The logger reports non-HTTP responses without raw payloads")
    func nonHTTPLogging() {
        let messages = LockedBox<[String]>([])
        let logger = NetworkingLogger { _, message in
            messages.withLock { $0.append(message) }
        }
        let response = URLResponse(
            url: URL(string: "file:///private/secret")!,
            mimeType: nil,
            expectedContentLength: 6,
            textEncodingName: nil
        )

        logger.log(response: response, data: Data("secret".utf8))

        #expect(messages.withLock { $0 } == ["Received a non-HTTP response."])
    }
}

private func requireSendable<T: Sendable>(_ value: T) {}

private struct SnapshotOnlyWebSocketConnection: WebSocketConnectionProtocol {
    let url = URL(string: "wss://example.com/socket")!
    let negotiatedSubprotocol: String? = nil
    let state = WebSocketConnectionState.closing

    func send(_ message: WebSocketMessage) async throws {}

    func receive() async throws -> WebSocketMessage {
        throw WebSocketError.connectionClosing
    }

    func ping() async throws {}

    func close(
        code: WebSocketCloseCode,
        reason: String?
    ) async throws {}
}
