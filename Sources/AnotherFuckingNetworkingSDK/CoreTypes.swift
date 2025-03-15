import Foundation

// MARK: - HTTPMethod

/// Because who doesn't love enumerating?
public enum HTTPMethod: String {
    case get    = "GET"
    case post   = "POST"
    case put    = "PUT"
    case delete = "DELETE"
    // add more (PATCH, HEAD, OPTIONS...) if your API needs them
}

// MARK: - NetworkError

/// A robust representation of the bullshit that can go wrong.
public enum NetworkError: LocalizedError {
    case invalidURL
    case requestFailed(statusCode: Int, data: Data?)
    case decodingFailed(Error)
    case unknown(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Fucked up: invalid URL."
        case .requestFailed(let statusCode, _):
            return "Fucked up: HTTP \(statusCode) returned."
        case .decodingFailed(let error):
            return "Fucked up: couldn't decode JSON. (\(error.localizedDescription))"
        case .unknown(let error):
            return "Fucked up: unknown error. (\(error.localizedDescription))"
        }
    }
}

// MARK: - Request

/// The blueprint for your networking calls.
/// Supply the path, method, query items, body, etc.
public protocol Request {
    associatedtype ReturnType: Decodable
    
    /// e.g. "users", "posts/1", etc.
    var path: String { get }
    
    /// GET, POST, etc. Default: .get
    var method: HTTPMethod { get }
    
    /// `?foo=bar` stuff. Default: nil.
    var queryItems: [URLQueryItem]? { get }
    
    /// Request body for POST/PUT. Default: nil.
    var body: Data? { get }
    
    /// Optional custom headers for this request. Default: nil.
    var headers: [String: String]? { get }
    
    /// Build the final URL from a baseURL (which we store in the client).
    func makeURL(baseURL: URL) -> URL?
}

// MARK: Defaults
public extension Request {
    var method: HTTPMethod { .get }
    var queryItems: [URLQueryItem]? { nil }
    var body: Data? { nil }
    var headers: [String: String]? { nil }
    
    func makeURL(baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        // tack on your path
        components.path = components.path + "/" + path
        
        // tack on any query items
        if let queryItems = queryItems, !queryItems.isEmpty {
            if components.queryItems == nil {
                components.queryItems = queryItems
            } else {
                components.queryItems?.append(contentsOf: queryItems)
            }
        }
        return components.url
    }
}

// MARK: - PaginatedRequest

/// If your request needs pagination, conform to this puppy.
public protocol PaginatedRequest: Request {
    /// Current page index or next-page token.
    var page: Int { get }
    /// Page size or limit. Adjust for your API.
    var pageSize: Int { get }
}

// MARK: - PaginatedResponse

/// Because APIs love sending back big lists in chunks.
public struct PaginatedResponse<T: Decodable>: Decodable {
    public let items: [T]
    public let currentPage: Int
    public let totalPages: Int

    /// Example logic: if current < total, next is current+1
    public var nextPage: Int? {
        currentPage < totalPages ? currentPage + 1 : nil
    }
} 