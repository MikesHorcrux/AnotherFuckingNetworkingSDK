import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("Request URL construction")
struct RequestURLTests {
    @Test("Path joining normalizes every slash combination", arguments: [
        ("https://example.com/api", "users", "https://example.com/api/users"),
        ("https://example.com/api/", "users", "https://example.com/api/users"),
        ("https://example.com/api", "/users", "https://example.com/api/users"),
        ("https://example.com/api/", "/users", "https://example.com/api/users"),
        ("https://example.com/api/", "users/", "https://example.com/api/users/"),
        ("https://example.com/api", "/", "https://example.com/api/"),
        ("https://example.com", "///", "https://example.com/"),
        ("https://example.com", "", "https://example.com"),
        ("https://example.com/api/", "", "https://example.com/api/")
    ])
    func normalizedPaths(base: String, path: String, expected: String) throws {
        let request = URLTestRequest(path: path)
        let baseURL = try #require(URL(string: base))
        let url = try #require(request.makeURL(baseURL: baseURL))
        #expect(url.absoluteString == expected)
    }

    @Test("Paths are percent encoded")
    func pathPercentEncoding() throws {
        let request = URLTestRequest(path: "users/Jane Doe/café/東京")
        let url = try #require(request.makeURL(baseURL: URL(string: "https://example.com")!))
        #expect(url.absoluteString
            == "https://example.com/users/Jane%20Doe/caf%C3%A9/%E6%9D%B1%E4%BA%AC")
    }

    @Test("Encoded base paths are preserved")
    func encodedBasePath() throws {
        let request = URLTestRequest(path: "users")
        let baseURL = try #require(URL(string: "https://example.com/api%2Fv1"))

        let url = try #require(request.makeURL(baseURL: baseURL))

        #expect(url.absoluteString == "https://example.com/api%2Fv1/users")
    }

    @Test("Requests explicitly distinguish decoded and percent-encoded paths")
    func explicitPathEncoding() throws {
        let baseURL = URL(string: "https://example.com")!
        let decoded = URLTestRequest(path: "users%2F42")
        let encoded = PercentEncodedURLTestRequest(path: "users%2F42")

        #expect(decoded.makeURL(baseURL: baseURL)?.absoluteString
            == "https://example.com/users%252F42")
        #expect(encoded.makeURL(baseURL: baseURL)?.absoluteString
            == "https://example.com/users%2F42")
        #expect(PercentEncodedURLTestRequest(path: "users%ZZ42")
            .makeURL(baseURL: baseURL) == nil)
        #expect(PercentEncodedURLTestRequest(path: "users/Jane Doe")
            .makeURL(baseURL: baseURL) == nil)
        #expect(PercentEncodedURLTestRequest(path: "users/café")
            .makeURL(baseURL: baseURL) == nil)
    }

    @Test("Base and request query items are both preserved")
    func queryMerging() throws {
        let request = URLTestRequest(
            path: "search",
            queryItems: [
                URLQueryItem(name: "tag", value: "swift"),
                URLQueryItem(name: "tag", value: "ios")
            ]
        )
        let baseURL = URL(string: "https://example.com/api?locale=en")!
        let url = try #require(request.makeURL(baseURL: baseURL))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

        #expect(items == [
            URLQueryItem(name: "locale", value: "en"),
            URLQueryItem(name: "tag", value: "swift"),
            URLQueryItem(name: "tag", value: "ios")
        ])
    }

    @Test("Global request customization sees the final request")
    func globalRequestCustomization() async throws {
        let captured = LockedBox<URLRequest?>(nil)
        let session = StubSession { request in
            captured.withLock { $0 = request }
            return .respond(try .http(
                for: request,
                statusCode: 204
            ))
        }
        let client = session.client(
            globalHeaders: ["X-Client": "sdk"],
            requestCustomizer: { request in
                #expect(request.httpMethod == "GET")
                #expect(request.value(forHTTPHeaderField: "X-Client") == "sdk")
                request.setValue("trace-42", forHTTPHeaderField: "X-Trace-ID")
            }
        )

        _ = try await client.send(URLTestRequest(path: "users"))

        let request = try #require(captured.withLock { $0 })
        #expect(request.url == session.baseURL.appendingPathComponent("users"))
        #expect(request.value(forHTTPHeaderField: "X-Trace-ID") == "trace-42")
    }

    @Test("Global request customization failures are structured")
    func globalRequestCustomizationFailure() async throws {
        let session = StubSession { request in
            .respond(try .http(for: request, statusCode: 204))
        }
        let client = session.client(
            requestCustomizer: { _ in
                throw CustomizerError.failed
            }
        )

        do {
            _ = try await client.send(URLTestRequest(path: "users"))
            Issue.record("Expected request customization to fail")
        } catch let error as NetworkError {
            guard case .requestConfigurationFailed(let underlying) = error else {
                Issue.record("Expected requestConfigurationFailed, got \(error)")
                return
            }
            #expect(underlying is CustomizerError)
        }
    }
}

private enum CustomizerError: Error, Sendable {
    case failed
}

private struct URLTestRequest: Request {
    typealias ReturnType = EmptyResponse

    let path: String
    let queryItems: [URLQueryItem]?

    init(path: String, queryItems: [URLQueryItem]? = nil) {
        self.path = path
        self.queryItems = queryItems
    }
}

private struct PercentEncodedURLTestRequest: Request {
    typealias ReturnType = EmptyResponse

    let path: String
    let pathEncoding = RequestPathEncoding.percentEncoded
}
