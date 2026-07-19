import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("Pagination")
struct PaginationTests {
    @Test("Pagination preserves base queries, filters, and custom URL behavior")
    func queryPreservation() async throws {
        let capturedURL = LockedBox<URL?>(nil)
        let body = Data(#"{"items":[{"id":1,"displayName":"Marvin"}],"currentPage":2,"totalPages":3}"#.utf8)
        let stub = StubSession { request in
            capturedURL.withLock { $0 = request.url }
            return .respond(try .http(for: request, data: body))
        }
        let baseURL = try #require(URL(string: "\(stub.baseURL.absoluteString)/v1?locale=en"))
        let request = UserPageRequest(page: 2, pageSize: 25)

        let response = try await stub.client(baseURL: baseURL).sendPage(request)
        let requestedURL = try #require(capturedURL.withLock { $0 })
        let components = try #require(URLComponents(
            url: requestedURL,
            resolvingAgainstBaseURL: false
        ))

        #expect(components.path == "/v1/users")
        #expect(components.queryItems == [
            URLQueryItem(name: "locale", value: "en"),
            URLQueryItem(name: "filter", value: "active"),
            URLQueryItem(name: "custom", value: "kept"),
            URLQueryItem(name: "page", value: "2"),
            URLQueryItem(name: "pageSize", value: "25")
        ])
        #expect(response.items == [TestUser(id: 1, displayName: "Marvin")])
        #expect(response.nextPage == 3)
    }

    @Test("Pagination replaces existing keys case-insensitively")
    func paginationKeyReplacement() async throws {
        let capturedItems = LockedBox<[URLQueryItem]>([])
        let body = Data(#"{"items":[],"currentPage":4,"totalPages":4}"#.utf8)
        let stub = StubSession { request in
            capturedItems.withLock {
                $0 = URLComponents(
                    url: request.url!,
                    resolvingAgainstBaseURL: false
                )?.queryItems ?? []
            }
            return .respond(try .http(for: request, data: body))
        }

        let response = try await stub.client().sendPage(ExistingPageRequest())

        #expect(capturedItems.withLock { $0 } == [
            URLQueryItem(name: "filter", value: "recent"),
            URLQueryItem(name: "page", value: "4"),
            URLQueryItem(name: "pageSize", value: "10")
        ])
        #expect(response.nextPage == nil)
    }

    @Test("Custom pagination key names are supported")
    func customKeys() async throws {
        let capturedItems = LockedBox<[URLQueryItem]>([])
        let body = Data(#"{"items":[],"currentPage":1,"totalPages":1}"#.utf8)
        let stub = StubSession { request in
            capturedItems.withLock {
                $0 = URLComponents(
                    url: request.url!,
                    resolvingAgainstBaseURL: false
                )?.queryItems ?? []
            }
            return .respond(try .http(for: request, data: body))
        }

        _ = try await stub.client().sendPage(CustomKeyPageRequest())

        #expect(capturedItems.withLock { $0 } == [
            URLQueryItem(name: "offset", value: "3"),
            URLQueryItem(name: "limit", value: "50")
        ])
    }
}

private struct UserPageRequest: PaginatedRequest {
    typealias ReturnType = TestUser

    let page: Int
    let pageSize: Int
    let path = "users"
    let queryItems: [URLQueryItem]? = [
        URLQueryItem(name: "filter", value: "active")
    ]

    func makeURL(baseURL: URL) -> URL? {
        guard let defaultURL = RequestURLBuilder.makeURL(for: self, baseURL: baseURL),
              var components = URLComponents(url: defaultURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = (components.queryItems ?? [])
            + [URLQueryItem(name: "custom", value: "kept")]
        return components.url
    }
}

private struct ExistingPageRequest: PaginatedRequest {
    typealias ReturnType = TestUser

    let page = 4
    let pageSize = 10
    let path = "users"
    let queryItems: [URLQueryItem]? = [
        URLQueryItem(name: "PAGE", value: "99"),
        URLQueryItem(name: "filter", value: "recent"),
        URLQueryItem(name: "pagesize", value: "99")
    ]
}

private struct CustomKeyPageRequest: PaginatedRequest {
    typealias ReturnType = TestUser

    let page = 3
    let pageSize = 50
    let pageQueryName = "offset"
    let pageSizeQueryName = "limit"
    let path = "users"
}

/// Calls the protocol's default URL builder from a custom implementation.
private enum RequestURLBuilder {
    private struct Wrapped<R: Request>: Request {
        typealias ReturnType = R.ReturnType
        let request: R
        var path: String { request.path }
        var method: HTTPMethod { request.method }
        var queryItems: [URLQueryItem]? { request.queryItems }
        var body: Data? { request.body }
        var headers: [String: String]? { request.headers }
    }

    static func makeURL<R: Request>(for request: R, baseURL: URL) -> URL? {
        Wrapped(request: request).makeURL(baseURL: baseURL)
    }
}
