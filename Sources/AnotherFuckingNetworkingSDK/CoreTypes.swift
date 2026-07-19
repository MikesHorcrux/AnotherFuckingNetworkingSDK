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

/// Describes whether a request path still needs percent encoding.
public enum RequestPathEncoding: Sendable {
    /// Treat ``HTTPRequest/path`` as decoded text and percent encode it.
    case decoded

    /// Treat ``HTTPRequest/path`` as an already percent-encoded path.
    case percentEncoded
}

// MARK: - NetworkError

/// An error produced while constructing, sending, or decoding a network request.
public enum NetworkError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case encodingFailed(any Error)
    case requestConfigurationFailed(any Error)
    case transport(URLError)
    case requestFailed(statusCode: Int, data: Data?)
    case emptyResponse(statusCode: Int)
    case decodingFailed(any Error)
    case fileOperationFailed(any Error)
    case unknown(any Error)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The request URL could not be constructed."
        case .invalidResponse:
            return "The server returned a non-HTTP response."
        case .encodingFailed(let error):
            return "The request body could not be encoded: \(error.localizedDescription)"
        case .requestConfigurationFailed(let error):
            return "The URL request could not be configured: \(error.localizedDescription)"
        case .transport(let error):
            return "The request failed before receiving a response: \(error.localizedDescription)"
        case .requestFailed(let statusCode, _):
            return "The server returned HTTP \(statusCode)."
        case .emptyResponse(let statusCode):
            return "The server returned an empty HTTP \(statusCode) response."
        case .decodingFailed(let error):
            return "The response could not be decoded: \(error.localizedDescription)"
        case .fileOperationFailed(let error):
            return "A network file operation failed: \(error.localizedDescription)"
        case .unknown(let error):
            return "The request failed unexpectedly: \(error.localizedDescription)"
        }
    }
}

// MARK: - HTTPRequest

/// The shared URL, method, header, and body description for an HTTP operation.
public protocol HTTPRequest: Sendable {
    /// The endpoint path relative to the client's base URL.
    var path: String { get }

    /// How ``path`` should be interpreted. The default is ``RequestPathEncoding/decoded``.
    var pathEncoding: RequestPathEncoding { get }

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

    /// Applies final request-specific URL loading options.
    ///
    /// This hook runs after the client has set the URL, method, merged headers,
    /// and encoded body. Use it for options such as cache policy, timeout,
    /// cookie handling, or network access constraints.
    func customize(_ urlRequest: inout URLRequest) throws
}

public extension HTTPRequest {
    var method: HTTPMethod { .get }
    var pathEncoding: RequestPathEncoding { .decoded }
    var queryItems: [URLQueryItem]? { nil }
    var body: Data? { nil }
    var headers: [String: String]? { nil }

    func makeURL(baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        if !path.isEmpty {
            let encodedPath: String
            switch pathEncoding {
            case .decoded:
                guard let value = path.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed
                ) else {
                    return nil
                }
                encodedPath = value
            case .percentEncoded:
                guard Self.isValidPercentEncodedPath(path) else {
                    return nil
                }
                encodedPath = path
            }

            let basePath = components.percentEncodedPath
            let normalizedBase = Self.droppingTrailingSlashes(from: basePath)
            let normalizedEndpoint = String(encodedPath.drop(while: { $0 == "/" }))

            if normalizedEndpoint.isEmpty {
                components.percentEncodedPath = normalizedBase.hasSuffix("/")
                    ? normalizedBase
                    : "\(normalizedBase)/"
            } else if normalizedBase.isEmpty {
                components.percentEncodedPath = "/\(normalizedEndpoint)"
            } else {
                components.percentEncodedPath = "\(normalizedBase)/\(normalizedEndpoint)"
            }
        }

        if let queryItems, !queryItems.isEmpty {
            components.queryItems = (components.queryItems ?? []) + queryItems
        }

        return components.url
    }

    func makeBody(using encoder: JSONEncoder) throws -> Data? {
        body
    }

    func customize(_ urlRequest: inout URLRequest) throws {}

    private static func isValidPercentEncodedPath(_ path: String) -> Bool {
        let scalars = Array(path.unicodeScalars)
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "%" {
                guard index + 2 < scalars.count,
                      scalars[index + 1].isASCIIHexDigit,
                      scalars[index + 2].isASCIIHexDigit else {
                    return false
                }
                index += 3
            } else {
                guard CharacterSet.urlPathAllowed.contains(scalar) else {
                    return false
                }
                index += 1
            }
        }

        return true
    }

    private static func droppingTrailingSlashes(from path: String) -> String {
        var result = path
        while result.last == "/" {
            result.removeLast()
        }
        return result
    }
}

// MARK: - Request

/// A type-safe HTTP request with a decoded response value.
public protocol Request: HTTPRequest {
    associatedtype ReturnType: Sendable

    /// Whether a successful response with no body should be passed to
    /// ``decode(_:response:using:)``. The default is `false`.
    var allowsEmptyResponseBody: Bool { get }

    /// Decodes a successful response using a fresh decoder from the client configuration.
    func decode(
        _ data: Data,
        response: HTTPURLResponse,
        using decoder: JSONDecoder
    ) throws -> ReturnType
}

public extension Request {
    var allowsEmptyResponseBody: Bool { false }
}

public extension Request where ReturnType: Decodable {
    func decode(
        _ data: Data,
        response: HTTPURLResponse,
        using decoder: JSONDecoder
    ) throws -> ReturnType {
        try decoder.decode(ReturnType.self, from: data)
    }
}

// MARK: - RawDataRequest

/// A request whose successful response body is returned without JSON decoding.
///
/// Empty successful bodies are returned as empty `Data` rather than producing
/// ``NetworkError/emptyResponse(statusCode:)``.
public protocol RawDataRequest: Request where ReturnType == Data {}

public extension RawDataRequest {
    var allowsEmptyResponseBody: Bool { true }

    func decode(
        _ data: Data,
        response: HTTPURLResponse,
        using decoder: JSONDecoder
    ) throws -> Data {
        data
    }
}

// MARK: - HTTP response metadata

/// Stable, `Sendable` metadata from an HTTP response.
public struct HTTPResponseMetadata: Equatable, Sendable {
    public let statusCode: Int
    public let url: URL?

    /// Response headers keyed by lowercase field name.
    public let headers: [String: String]

    public init(
        statusCode: Int,
        url: URL? = nil,
        headers: [String: String] = [:]
    ) {
        self.statusCode = statusCode
        self.url = url
        self.headers = Self.normalizedHeaders(headers)
    }

    /// Returns a header value using case-insensitive field-name matching.
    public func value(forHTTPHeaderField name: String) -> String? {
        headers[name.lowercased()]
    }

    init(_ response: HTTPURLResponse) {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }

        self.init(
            statusCode: response.statusCode,
            url: response.url,
            headers: headers
        )
    }

    private static func normalizedHeaders(
        _ headers: [String: String]
    ) -> [String: String] {
        var normalized: [String: String] = [:]
        for name in headers.keys.sorted() {
            normalized[name.lowercased()] = headers[name]
        }
        return normalized
    }
}

/// A decoded value together with the status, URL, and headers that produced it.
public struct HTTPResponse<Value: Sendable>: Sendable {
    public let value: Value
    public let data: Data
    public let metadata: HTTPResponseMetadata

    public init(
        value: Value,
        data: Data = Data(),
        metadata: HTTPResponseMetadata
    ) {
        self.value = value
        self.data = data
        self.metadata = metadata
    }

    public var statusCode: Int { metadata.statusCode }
    public var url: URL? { metadata.url }
    public var headers: [String: String] { metadata.headers }

    public func value(forHTTPHeaderField name: String) -> String? {
        metadata.value(forHTTPHeaderField: name)
    }
}

extension HTTPResponse: Equatable where Value: Equatable {}

private extension Unicode.Scalar {
    var isASCIIHexDigit: Bool {
        switch value {
        case 48...57, 65...70, 97...102:
            return true
        default:
            return false
        }
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
public protocol PaginatedRequest: Request where ReturnType: Decodable {
    var page: Int { get }
    var pageSize: Int { get }

    /// The query name used for ``page``. The default is `page`.
    var pageQueryName: String { get }

    /// The query name used for ``pageSize``. The default is `pageSize`.
    var pageSizeQueryName: String { get }

    /// Decodes a paginated response with the client's configured decoder.
    func decodePage(
        _ data: Data,
        response: HTTPURLResponse,
        using decoder: JSONDecoder
    ) throws -> PaginatedResponse<ReturnType>
}

public extension PaginatedRequest {
    var pageQueryName: String { "page" }
    var pageSizeQueryName: String { "pageSize" }

    func decodePage(
        _ data: Data,
        response: HTTPURLResponse,
        using decoder: JSONDecoder
    ) throws -> PaginatedResponse<ReturnType> {
        try decoder.decode(PaginatedResponse<ReturnType>.self, from: data)
    }
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
