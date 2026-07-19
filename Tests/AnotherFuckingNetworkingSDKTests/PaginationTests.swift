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

    @Test("A paginated request may customize response decoding")
    func customPageDecoding() async throws {
        let body = Data(#"{"results":[{"id":9,"displayName":"Custom"}],"page":3,"pages":7}"#.utf8)
        let stub = StubSession { request in
            .respond(try .http(for: request, data: body))
        }

        let response = try await stub.client().sendPage(CustomPageDecodingRequest())

        #expect(response == PaginatedResponse(
            items: [TestUser(id: 9, displayName: "Custom")],
            currentPage: 3,
            totalPages: 7
        ))
    }

    @Test("Cancellation from custom page decoding is preserved")
    func customPageDecodingCancellation() async throws {
        let stub = StubSession { request in
            .respond(try .http(for: request, data: Data("{}".utf8)))
        }

        do {
            _ = try await stub.client().sendPage(CancellingPageDecodingRequest())
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("Pagination preserves explicitly percent-encoded paths")
    func percentEncodedPath() async throws {
        let capturedURL = LockedBox<URL?>(nil)
        let body = Data(#"{"items":[],"currentPage":1,"totalPages":1}"#.utf8)
        let stub = StubSession { request in
            capturedURL.withLock { $0 = request.url }
            return .respond(try .http(for: request, data: body))
        }

        _ = try await stub.client().sendPage(PercentEncodedPageRequest())

        #expect(capturedURL.withLock { $0 }?.absoluteString.contains("/folders%2F42?") == true)
        #expect(capturedURL.withLock { $0 }?.absoluteString.contains("%252F") == false)
    }

    @Test("Pagination runs final request customization after adding page items")
    func requestCustomization() async throws {
        let capturedQueryHeader = LockedBox<String?>(nil)
        let body = Data(#"{"items":[],"currentPage":2,"totalPages":2}"#.utf8)
        let stub = StubSession { request in
            capturedQueryHeader.withLock {
                $0 = request.value(forHTTPHeaderField: "X-Final-Query")
            }
            return .respond(try .http(
                for: request,
                statusCode: 206,
                headers: ["X-Page-Source": "fixture"],
                data: body
            ))
        }

        let response = try await stub.client().sendPageResponse(
            CustomizedPageRequest()
        )

        #expect(capturedQueryHeader.withLock { $0 } == "filter=active&page=2&pageSize=10")
        #expect(response.statusCode == 206)
        #expect(response.value(forHTTPHeaderField: "x-page-source") == "fixture")
    }

    @Test("Pagination forwards request-specific status policies")
    func statusPolicyForwarding() async throws {
        let body = Data(#"{"items":[{"id":9,"displayName":"Conflict"}],"currentPage":1,"totalPages":1}"#.utf8)
        let stub = StubSession { request in
            .respond(try .http(
                for: request,
                statusCode: 409,
                data: body
            ))
        }

        let response = try await stub.client().sendPageResponse(
            StatusPolicyPageRequest()
        )

        #expect(response.statusCode == 409)
        #expect(response.value.items == [
            TestUser(id: 9, displayName: "Conflict")
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

private struct CustomPageDecodingRequest: PaginatedRequest {
    typealias ReturnType = TestUser

    private struct Envelope: Decodable {
        let results: [TestUser]
        let page: Int
        let pages: Int
    }

    let page = 3
    let pageSize = 20
    let path = "custom-page"

    func decodePage(
        _ data: Data,
        response: HTTPURLResponse,
        using decoder: JSONDecoder
    ) throws -> PaginatedResponse<TestUser> {
        let envelope = try decoder.decode(Envelope.self, from: data)
        return PaginatedResponse(
            items: envelope.results,
            currentPage: envelope.page,
            totalPages: envelope.pages
        )
    }
}

private struct CancellingPageDecodingRequest: PaginatedRequest {
    typealias ReturnType = TestUser

    let page = 1
    let pageSize = 20
    let path = "cancel-page"

    func decodePage(
        _ data: Data,
        response: HTTPURLResponse,
        using decoder: JSONDecoder
    ) throws -> PaginatedResponse<TestUser> {
        throw CancellationError()
    }
}

private struct PercentEncodedPageRequest: PaginatedRequest {
    typealias ReturnType = TestUser

    let page = 1
    let pageSize = 20
    let path = "folders%2F42"
    let pathEncoding = RequestPathEncoding.percentEncoded
}

private struct CustomizedPageRequest: PaginatedRequest {
    typealias ReturnType = TestUser

    let page = 2
    let pageSize = 10
    let path = "customized-page"
    let queryItems: [URLQueryItem]? = [
        URLQueryItem(name: "filter", value: "active")
    ]

    func customize(_ urlRequest: inout URLRequest) throws {
        urlRequest.setValue(
            urlRequest.url?.query,
            forHTTPHeaderField: "X-Final-Query"
        )
    }
}

private struct StatusPolicyPageRequest: PaginatedRequest {
    typealias ReturnType = TestUser

    let page = 1
    let pageSize = 20
    let path = "status-policy-page"
    let acceptedStatusCodes = HTTPStatusPolicy.codes([409])
}

/// Calls the protocol's default URL builder from a custom implementation.
private enum RequestURLBuilder {
    private struct Wrapped<R: Request>: Request {
        typealias ReturnType = R.ReturnType
        let request: R
        var path: String { request.path }
        var pathEncoding: RequestPathEncoding { request.pathEncoding }
        var method: HTTPMethod { request.method }
        var queryItems: [URLQueryItem]? { request.queryItems }
        var body: Data? { request.body }
        var headers: [String: String]? { request.headers }
        var acceptedStatusCodes: HTTPStatusPolicy {
            request.acceptedStatusCodes
        }
        var allowsEmptyResponseBody: Bool { request.allowsEmptyResponseBody }

        func makeBody(using encoder: JSONEncoder) throws -> Data? {
            try request.makeBody(using: encoder)
        }

        func customize(_ urlRequest: inout URLRequest) throws {
            try request.customize(&urlRequest)
        }

        func decode(
            _ data: Data,
            response: HTTPURLResponse,
            using decoder: JSONDecoder
        ) throws -> R.ReturnType {
            try request.decode(data, response: response, using: decoder)
        }
    }

    static func makeURL<R: Request>(for request: R, baseURL: URL) -> URL? {
        Wrapped(request: request).makeURL(baseURL: baseURL)
    }
}
