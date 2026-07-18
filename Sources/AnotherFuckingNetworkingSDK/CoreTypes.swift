import Foundation

// MARK: - HTTPMethod

/// An HTTP request method.
public enum HTTPMethod: String, CaseIterable, Sendable {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case options = "OPTIONS"
}

// MARK: - NetworkError

/// An error produced while constructing, sending, or decoding a network request.
public enum NetworkError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case encodingFailed(any Error)
    case transport(URLError)
    case requestFailed(statusCode: Int, data: Data?)
    case emptyResponse(statusCode: Int)
    case decodingFailed(any Error)
    case unknown(any Error)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The request URL could not be constructed."
        case .invalidResponse:
            return "The server returned a non-HTTP response."
        case .encodingFailed(let error):
            return "The request body could not be encoded: \(error.localizedDescription)"
        case .transport(let error):
            return "The request failed before receiving a response: \(error.localizedDescription)"
        case .requestFailed(let statusCode, _):
            return "The server returned HTTP \(statusCode)."
        case .emptyResponse(let statusCode):
            return "The server returned an empty HTTP \(statusCode) response."
        case .decodingFailed(let error):
            return "The response could not be decoded: \(error.localizedDescription)"
        case .unknown(let error):
            return "The request failed unexpectedly: \(error.localizedDescription)"
        }
    }
}

// MARK: - Request

/// A type-safe description of an HTTP request and its decoded response.
public protocol Request: Sendable {
    associatedtype ReturnType: Decodable & Sendable

    /// The endpoint path relative to the client's base URL.
    var path: String { get }

    /// The HTTP method. The default is ``HTTPMethod/get``.
    var method: HTTPMethod { get }

    /// Query items appended after any query items already present in the base URL.
    var queryItems: [URLQueryItem]? { get }

    /// A pre-encoded request body.
    ///
    /// Requests that need the client's configured encoder should implement
    /// ``makeBody(using:)`` instead.
    var body: Data? { get }

    /// Headers applied to this request. They override matching client headers
    /// case-insensitively.
    var headers: [String: String]? { get }

    /// Builds the final URL from the client's base URL.
    func makeURL(baseURL: URL) -> URL?

    /// Builds the body using a fresh encoder from the client configuration.
    func makeBody(using encoder: JSONEncoder) throws -> Data?

    /// Decodes a successful response using a fresh decoder from the client configuration.
    func decode(
        _ data: Data,
        response: HTTPURLResponse,
        using decoder: JSONDecoder
    ) throws -> ReturnType
}

public extension Request {
    var method: HTTPMethod { .get }
    var queryItems: [URLQueryItem]? { nil }
    var body: Data? { nil }
    var headers: [String: String]? { nil }

    func makeURL(baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let basePath = components.path.trimmingCharacters(in: Self.pathSeparators)
        let endpointPath = path.trimmingCharacters(in: Self.pathSeparators)
        let joinedPath = [basePath, endpointPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")

        components.path = joinedPath.isEmpty ? "" : "/\(joinedPath)"

        if let queryItems, !queryItems.isEmpty {
            components.queryItems = (components.queryItems ?? []) + queryItems
        }

        return components.url
    }

    func makeBody(using encoder: JSONEncoder) throws -> Data? {
        body
    }

    func decode(
        _ data: Data,
        response: HTTPURLResponse,
        using decoder: JSONDecoder
    ) throws -> ReturnType {
        try decoder.decode(ReturnType.self, from: data)
    }

    private static var pathSeparators: CharacterSet {
        CharacterSet(charactersIn: "/")
    }
}

// MARK: - EmptyResponse

/// A successful response that intentionally carries no body.
public struct EmptyResponse: Decodable, Equatable, Sendable {
    public init() {}

    public init(from decoder: any Decoder) throws {
        self.init()
    }
}

// MARK: - Pagination

/// A page-number-based request.
public protocol PaginatedRequest: Request {
    var page: Int { get }
    var pageSize: Int { get }

    /// The query name used for ``page``. The default is `page`.
    var pageQueryName: String { get }

    /// The query name used for ``pageSize``. The default is `pageSize`.
    var pageSizeQueryName: String { get }
}

public extension PaginatedRequest {
    var pageQueryName: String { "page" }
    var pageSizeQueryName: String { "pageSize" }
}

/// A decoded page of response items.
public struct PaginatedResponse<T: Decodable & Sendable>: Decodable, Sendable {
    public let items: [T]
    public let currentPage: Int
    public let totalPages: Int

    public init(items: [T], currentPage: Int, totalPages: Int) {
        self.items = items
        self.currentPage = currentPage
        self.totalPages = totalPages
    }

    public var nextPage: Int? {
        currentPage < totalPages ? currentPage + 1 : nil
    }
}

extension PaginatedResponse: Equatable where T: Equatable {}
