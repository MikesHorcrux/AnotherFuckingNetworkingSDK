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
            (.requestFailed(statusCode: 429, data: nil), "429"),
            (.emptyResponse(statusCode: 204), "204"),
            (.decodingFailed(underlying), "fixture detail"),
            (.fileOperationFailed(underlying), "fixture detail"),
            (.unknown(underlying), "fixture detail")
        ]

        for (error, expectedText) in cases {
            #expect(error.localizedDescription.contains(expectedText))
        }
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
