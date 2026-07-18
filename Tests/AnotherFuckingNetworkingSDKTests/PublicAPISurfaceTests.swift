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
