import Foundation
import os.log

// MARK: - APIClient

/// The star of the show, ignoring all good naming conventions for comedic effect.
public class APIClient {
    /// Because everyone needs a shared instance, right?
    public static let shared = APIClient()
    
    /// The root URL, like "https://api.example.com"
    public var baseURL: URL?
    
    /// Throw whatever headers you want in here. We'll merge them with request-specific ones.
    public var globalHeaders: [String: String] = [:]
    
    /// If you want to see cURL logs, set a logger. Or nil to ignore logs.
    private let logger: NetworkingLogger?
    
    private let urlSession: URLSession
    
    /// Initialize your fancy client.
    public init(baseURL: URL? = nil,
                urlSession: URLSession = .shared,
                logger: NetworkingLogger? = NetworkingLogger()) {
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.logger = logger
    }
    
    // MARK: - Public async methods

    /// Send a request, decode to `R.ReturnType`.
    ///
    /// - Parameter request: A type conforming to `Request`.
    /// - Throws: `NetworkError` if something goes wrong.
    /// - Returns: Decoded response of type `R.ReturnType`.
    public func send<R: Request>(_ request: R) async throws -> R.ReturnType {
        guard let baseURL = baseURL,
              let url = request.makeURL(baseURL: baseURL) else {
            throw NetworkError.invalidURL
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        
        // Merge global + request-specific headers
        var allHeaders = globalHeaders
        if let reqHeaders = request.headers {
            allHeaders = allHeaders.merged(with: reqHeaders)
        }
        for (key, value) in allHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        
        urlRequest.httpBody = request.body
        
        logger?.log(request: urlRequest)
        
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: urlRequest)
        } catch {
            throw NetworkError.unknown(error)
        }
        
        logger?.log(response: response, data: data)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.requestFailed(statusCode: -1, data: nil)
        }
        
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NetworkError.requestFailed(statusCode: httpResponse.statusCode, data: data)
        }
        
        do {
            return try JSONDecoder().decode(R.ReturnType.self, from: data)
        } catch {
            throw NetworkError.decodingFailed(error)
        }
    }
    
    /// If you're feeling fancy, you can handle paginated calls here.
    public func sendPage<R: PaginatedRequest>(_ request: R) async throws -> PaginatedResponse<R.ReturnType> {
        let overriddenItems: [URLQueryItem] = [
            URLQueryItem(name: "page", value: "\(request.page)"),
            URLQueryItem(name: "pageSize", value: "\(request.pageSize)")
        ]
        let wrapper = PaginatedRequestWrapper(request: request, newQueryItems: overriddenItems)
        return try await send(wrapper)
    }
}

// MARK: - PaginatedRequestWrapper

/// Internal wrapper for handling paginated requests
internal struct PaginatedRequestWrapper<Inner: PaginatedRequest>: Request {
    typealias ReturnType = PaginatedResponse<Inner.ReturnType>
    
    private let wrapped: Inner
    private let overrideQueryItems: [URLQueryItem]
    
    init(request: Inner, newQueryItems: [URLQueryItem]) {
        self.wrapped = request
        self.overrideQueryItems = newQueryItems
    }
    
    var path: String { wrapped.path }
    var method: HTTPMethod { wrapped.method }
    var headers: [String : String]? { wrapped.headers }
    var body: Data? { wrapped.body }
    var queryItems: [URLQueryItem]? { overrideQueryItems }
    
    func makeURL(baseURL: URL) -> URL? {
        guard var comp = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        comp.path = comp.path + "/" + path
        if !overrideQueryItems.isEmpty {
            comp.queryItems = overrideQueryItems
        }
        return comp.url
    }
} 