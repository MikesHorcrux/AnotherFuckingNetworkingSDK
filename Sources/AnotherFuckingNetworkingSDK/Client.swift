import Foundation

/// A concurrency-safe client capable of sending typed requests.
public protocol APIClientProtocol: Sendable {
    func send<R: Request>(_ request: R) async throws -> R.ReturnType

    func sendPage<R: PaginatedRequest>(
        _ request: R
    ) async throws -> PaginatedResponse<R.ReturnType>
}

/// A URLSession-backed API client.
///
/// Configuration mutations are synchronized. Each request takes one atomic
/// configuration snapshot before doing any work, so an in-flight request never
/// observes a partially updated base URL, header set, or codec configuration.
public final class APIClient: APIClientProtocol, Sendable {
    public typealias EncoderFactory = @Sendable () -> JSONEncoder
    public typealias DecoderFactory = @Sendable () -> JSONDecoder

    /// A process-wide client for applications that prefer shared configuration.
    /// Dependency-injected instances are recommended for services and tests.
    public static let shared = APIClient()

    /// Mutable client configuration protected by ``updateConfiguration(_:)``.
    public struct Configuration: Sendable {
        public var baseURL: URL?
        public var globalHeaders: [String: String]
        public var encoderFactory: EncoderFactory
        public var decoderFactory: DecoderFactory

        public init(
            baseURL: URL? = nil,
            globalHeaders: [String: String] = [:],
            encoderFactory: @escaping EncoderFactory = { JSONEncoder() },
            decoderFactory: @escaping DecoderFactory = { JSONDecoder() }
        ) {
            self.baseURL = baseURL
            self.globalHeaders = globalHeaders
            self.encoderFactory = encoderFactory
            self.decoderFactory = decoderFactory
        }
    }

    /// The complete current configuration snapshot.
    public var configuration: Configuration {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    /// The root URL used to resolve request paths.
    public var baseURL: URL? {
        get { state.withLock { $0.baseURL } }
        set { state.withLock { $0.baseURL = newValue } }
    }

    /// Headers applied to every request unless overridden by a request header.
    public var globalHeaders: [String: String] {
        get { state.withLock { $0.globalHeaders } }
        set { state.withLock { $0.globalHeaders = newValue } }
    }

    private let state: Locked<Configuration>
    private let urlSession: URLSession
    private let logger: NetworkingLogger?

    public init(
        baseURL: URL? = nil,
        urlSession: URLSession = .shared,
        globalHeaders: [String: String] = [:],
        encoderFactory: @escaping EncoderFactory = { JSONEncoder() },
        decoderFactory: @escaping DecoderFactory = { JSONDecoder() },
        logger: NetworkingLogger? = nil
    ) {
        state = Locked(
            Configuration(
                baseURL: baseURL,
                globalHeaders: globalHeaders,
                encoderFactory: encoderFactory,
                decoderFactory: decoderFactory
            )
        )
        self.urlSession = urlSession
        self.logger = logger
    }

    /// Atomically updates multiple configuration values.
    public func updateConfiguration(
        _ update: @Sendable (inout Configuration) -> Void
    ) {
        state.withLock(update)
    }

    /// Sends a request and decodes its declared response type.
    public func send<R: Request>(_ request: R) async throws -> R.ReturnType {
        try Task.checkCancellation()
        let configuration = state.withLock { $0 }

        guard let baseURL = configuration.baseURL,
              let url = request.makeURL(baseURL: baseURL) else {
            throw NetworkError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue

        let headers = Self.mergingHeaders(
            defaults: configuration.globalHeaders,
            overrides: request.headers ?? [:]
        )
        for (name, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        do {
            urlRequest.httpBody = try request.makeBody(using: configuration.encoderFactory())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NetworkError.encodingFailed(error)
        }

        try Task.checkCancellation()
        logger?.log(request: urlRequest)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled, Task.isCancelled {
                throw CancellationError()
            }
            throw NetworkError.transport(error)
        } catch {
            throw NetworkError.unknown(error)
        }

        try Task.checkCancellation()
        logger?.log(response: response, data: data)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NetworkError.requestFailed(
                statusCode: httpResponse.statusCode,
                data: data
            )
        }

        let hasSemanticallyEmptyBody = data.isEmpty
            || httpResponse.statusCode == 204
            || httpResponse.statusCode == 205

        if hasSemanticallyEmptyBody {
            if let emptyResponse = EmptyResponse() as? R.ReturnType {
                return emptyResponse
            }
            throw NetworkError.emptyResponse(statusCode: httpResponse.statusCode)
        }

        do {
            return try request.decode(
                data,
                response: httpResponse,
                using: configuration.decoderFactory()
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NetworkError.decodingFailed(error)
        }
    }

    /// Sends a page-number-based request while preserving its existing URL.
    public func sendPage<R: PaginatedRequest>(
        _ request: R
    ) async throws -> PaginatedResponse<R.ReturnType> {
        let wrapper = PaginatedRequestWrapper(request: request)
        return try await send(wrapper)
    }

    private static func mergingHeaders(
        defaults: [String: String],
        overrides: [String: String]
    ) -> [String: String] {
        var result = normalizedHeaders(defaults)
        for (name, value) in normalizedHeaders(overrides) {
            result[name] = value
        }
        return result
    }

    /// Collapses invalid case-variant duplicates predictably. The
    /// lexicographically last spelling wins before names are lowercased.
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

// MARK: - PaginatedRequestWrapper

private struct PaginatedRequestWrapper<Inner: PaginatedRequest>: Request {
    typealias ReturnType = PaginatedResponse<Inner.ReturnType>

    private let wrapped: Inner

    init(request: Inner) {
        wrapped = request
    }

    var path: String { wrapped.path }
    var pathEncoding: RequestPathEncoding { wrapped.pathEncoding }
    var method: HTTPMethod { wrapped.method }
    var headers: [String: String]? { wrapped.headers }
    var body: Data? { wrapped.body }
    var queryItems: [URLQueryItem]? { wrapped.queryItems }

    func makeURL(baseURL: URL) -> URL? {
        guard let requestURL = wrapped.makeURL(baseURL: baseURL),
              var components = URLComponents(
                url: requestURL,
                resolvingAgainstBaseURL: false
              ) else {
            return nil
        }

        let paginationNames = [wrapped.pageQueryName, wrapped.pageSizeQueryName]
        var queryItems = (components.queryItems ?? []).filter { item in
            !paginationNames.contains {
                $0.caseInsensitiveCompare(item.name) == .orderedSame
            }
        }
        queryItems.append(URLQueryItem(
            name: wrapped.pageQueryName,
            value: String(wrapped.page)
        ))
        queryItems.append(URLQueryItem(
            name: wrapped.pageSizeQueryName,
            value: String(wrapped.pageSize)
        ))
        components.queryItems = queryItems

        return components.url
    }

    func makeBody(using encoder: JSONEncoder) throws -> Data? {
        try wrapped.makeBody(using: encoder)
    }

    func decode(
        _ data: Data,
        response: HTTPURLResponse,
        using decoder: JSONDecoder
    ) throws -> PaginatedResponse<Inner.ReturnType> {
        try wrapped.decodePage(data, response: response, using: decoder)
    }
}

// MARK: - Locking

private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func withLock<Result>(
        _ operation: (inout Value) throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation(&value)
    }
}
