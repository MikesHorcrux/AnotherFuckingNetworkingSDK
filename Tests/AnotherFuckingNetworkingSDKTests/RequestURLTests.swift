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
        ("https://example.com", "", "https://example.com")
    ])
    func normalizedPaths(base: String, path: String, expected: String) throws {
        let request = URLTestRequest(path: path)
        let baseURL = try #require(URL(string: base))
        let url = try #require(request.makeURL(baseURL: baseURL))
        #expect(url.absoluteString == expected)
    }

    @Test("Paths are percent encoded")
    func pathPercentEncoding() throws {
        let request = URLTestRequest(path: "users/Jane Doe")
        let url = try #require(request.makeURL(baseURL: URL(string: "https://example.com")!))
        #expect(url.absoluteString == "https://example.com/users/Jane%20Doe")
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
