import Foundation

/// A concurrency-safe client capable of sending typed requests.
public protocol APIClientProtocol: Sendable {
    func send<R: Request>(_ request: R) async throws -> R.ReturnType

    func sendPage<R: PaginatedRequest>(
        _ request: R
    ) async throws -> PaginatedResponse<R.ReturnType>
}

/// An API client that can also return HTTP response metadata.
public protocol APIClientResponseProtocol: APIClientProtocol {
    func sendResponse<R: Request>(
        _ request: R
    ) async throws -> HTTPResponse<R.ReturnType>

    func sendPageResponse<R: PaginatedRequest>(
        _ request: R
    ) async throws -> HTTPResponse<PaginatedResponse<R.ReturnType>>
}

/// An API client that can upload memory or files and download directly to disk.
public protocol APIClientTransferProtocol: APIClientResponseProtocol {
    func upload<R: Request>(
        _ request: R,
        from body: UploadBody
    ) async throws -> HTTPResponse<R.ReturnType>

    func download<R: DownloadRequest>(
        _ request: R,
        to destination: DownloadDestination
    ) async throws -> DownloadResponse
}

public extension APIClientTransferProtocol {
    /// Downloads to a unique temporary file owned by the caller.
    func download<R: DownloadRequest>(
        _ request: R
    ) async throws -> DownloadResponse {
        try await download(request, to: .temporary)
    }
}

/// A URLSession-backed API client.
///
/// Configuration mutations are synchronized. Each request takes one atomic
/// configuration snapshot before doing any work, so an in-flight request never
/// observes a partially updated base URL, header set, or codec configuration.
public final class APIClient: APIClientTransferProtocol, Sendable {
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
        try await sendResponse(request).value
    }

    /// Sends a request and returns its decoded value with HTTP metadata.
    public func sendResponse<R: Request>(
        _ request: R
    ) async throws -> HTTPResponse<R.ReturnType> {
        try Task.checkCancellation()
        let configuration = state.withLock { $0 }
        let urlRequest = try Self.makeURLRequest(
            request,
            configuration: configuration
        )
        let (data, httpResponse) = try await performDataRequest(urlRequest) {
            try await self.urlSession.data(for: urlRequest)
        }
        return try Self.makeResponse(
            request,
            data: data,
            response: httpResponse,
            configuration: configuration
        )
    }

    /// Sends a page-number-based request while preserving its existing URL.
    public func sendPage<R: PaginatedRequest>(
        _ request: R
    ) async throws -> PaginatedResponse<R.ReturnType> {
        try await sendPageResponse(request).value
    }

    /// Sends a page-number-based request and returns HTTP metadata.
    public func sendPageResponse<R: PaginatedRequest>(
        _ request: R
    ) async throws -> HTTPResponse<PaginatedResponse<R.ReturnType>> {
        let wrapper = PaginatedRequestWrapper(request: request)
        return try await sendResponse(wrapper)
    }

    /// Uploads bytes with a URLSession upload task and decodes the response.
    public func upload<R: Request>(
        _ request: R,
        from body: UploadBody
    ) async throws -> HTTPResponse<R.ReturnType> {
        try Task.checkCancellation()
        let configuration = state.withLock { $0 }

        let bodySource: RequestBodySource
        switch body {
        case .data(let data):
            bodySource = .provided(data)
        case .file(let fileURL):
            try Self.validateUploadSource(fileURL)
            bodySource = .provided(nil)
        }

        let urlRequest = try Self.makeURLRequest(
            request,
            configuration: configuration,
            bodySource: bodySource
        )

        let result: (Data, HTTPURLResponse)
        switch body {
        case .data(let data):
            result = try await performDataRequest(urlRequest) {
                try await self.urlSession.upload(for: urlRequest, from: data)
            }
        case .file(let fileURL):
            result = try await performDataRequest(urlRequest) {
                try await self.urlSession.upload(for: urlRequest, fromFile: fileURL)
            }
        }

        return try Self.makeResponse(
            request,
            data: result.0,
            response: result.1,
            configuration: configuration
        )
    }

    /// Downloads a response body directly to a durable file location.
    public func download<R: DownloadRequest>(
        _ request: R,
        to destination: DownloadDestination
    ) async throws -> DownloadResponse {
        try Task.checkCancellation()
        try Self.validateDownloadDestination(destination)
        let configuration = state.withLock { $0 }
        let urlRequest = try Self.makeURLRequest(
            request,
            configuration: configuration
        )

        try Task.checkCancellation()
        logger?.log(request: urlRequest)

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await urlSession.download(for: urlRequest)
        } catch {
            try Self.throwTransportError(error)
        }

        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            logger?.log(response: response, data: Data())
            throw NetworkError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorData = Self.readDownloadErrorData(at: temporaryURL)
            logger?.log(response: response, data: errorData ?? Data())
            throw NetworkError.requestFailed(
                statusCode: httpResponse.statusCode,
                data: errorData
            )
        }

        logger?.log(response: response, data: Data())
        let storedURL: URL
        do {
            storedURL = try Self.storeDownloadedFile(
                at: temporaryURL,
                destination: destination
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NetworkError {
            throw error
        } catch {
            throw NetworkError.fileOperationFailed(error)
        }

        return DownloadResponse(
            fileURL: storedURL,
            metadata: HTTPResponseMetadata(httpResponse)
        )
    }

    private enum RequestBodySource: Sendable {
        case encoded
        case provided(Data?)
    }

    private static func makeURLRequest<R: HTTPRequest>(
        _ request: R,
        configuration: Configuration,
        bodySource: RequestBodySource = .encoded
    ) throws -> URLRequest {
        guard let baseURL = configuration.baseURL,
              let url = request.makeURL(baseURL: baseURL) else {
            throw NetworkError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue

        let headers = mergingHeaders(
            defaults: configuration.globalHeaders,
            overrides: request.headers ?? [:]
        )
        for (name, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        switch bodySource {
        case .encoded:
            do {
                urlRequest.httpBody = try request.makeBody(
                    using: configuration.encoderFactory()
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw NetworkError.encodingFailed(error)
            }
        case .provided(let data):
            urlRequest.httpBody = data
        }

        do {
            try request.customize(&urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NetworkError.requestConfigurationFailed(error)
        }

        return urlRequest
    }

    private func performDataRequest(
        _ urlRequest: URLRequest,
        operation: @Sendable () async throws -> (Data, URLResponse)
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        logger?.log(request: urlRequest)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await operation()
        } catch {
            try Self.throwTransportError(error)
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

        return (data, httpResponse)
    }

    private static func makeResponse<R: Request>(
        _ request: R,
        data: Data,
        response: HTTPURLResponse,
        configuration: Configuration
    ) throws -> HTTPResponse<R.ReturnType> {
        let value: R.ReturnType
        do {
            value = try decode(
                request,
                data: data,
                response: response,
                decoder: configuration.decoderFactory()
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NetworkError {
            throw error
        } catch {
            throw NetworkError.decodingFailed(error)
        }

        return HTTPResponse(
            value: value,
            data: data,
            metadata: HTTPResponseMetadata(response)
        )
    }

    private static func throwTransportError(
        _ error: any Error
    ) throws -> Never {
        if error is CancellationError {
            throw CancellationError()
        }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled, Task.isCancelled {
                throw CancellationError()
            }
            throw NetworkError.transport(urlError)
        }
        throw NetworkError.unknown(error)
    }

    private static func validateDownloadDestination(
        _ destination: DownloadDestination
    ) throws {
        guard case .file(let url, let overwriteExisting) = destination else {
            return
        }
        guard url.isFileURL else {
            throw NetworkError.fileOperationFailed(
                FileTransferError.destinationIsNotFileURL(url)
            )
        }
        if !overwriteExisting, FileManager.default.fileExists(atPath: url.path) {
            throw NetworkError.fileOperationFailed(
                FileTransferError.destinationAlreadyExists(url)
            )
        }
    }

    private static func validateUploadSource(_ url: URL) throws {
        guard url.isFileURL else {
            throw NetworkError.fileOperationFailed(
                FileTransferError.sourceIsNotFileURL(url)
            )
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ) else {
            throw NetworkError.fileOperationFailed(
                FileTransferError.sourceDoesNotExist(url)
            )
        }
        guard !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw NetworkError.fileOperationFailed(
                FileTransferError.sourceIsNotReadableFile(url)
            )
        }
    }

    private static func storeDownloadedFile(
        at temporaryURL: URL,
        destination: DownloadDestination
    ) throws -> URL {
        let fileManager = FileManager.default

        switch destination {
        case .temporary:
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "AnotherFuckingNetworkingSDK-Downloads",
                    isDirectory: true
                )
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let destinationURL = directory.appendingPathComponent(
                UUID().uuidString,
                isDirectory: false
            )
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            return destinationURL

        case .file(let destinationURL, let overwriteExisting):
            guard destinationURL.isFileURL else {
                throw FileTransferError.destinationIsNotFileURL(destinationURL)
            }

            if fileManager.fileExists(atPath: destinationURL.path) {
                guard overwriteExisting else {
                    throw FileTransferError.destinationAlreadyExists(destinationURL)
                }
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }
            return destinationURL
        }
    }

    /// Avoids loading an unexpectedly huge failed download into memory.
    private static func readDownloadErrorData(at url: URL) -> Data? {
        let maximumBytes = 1_048_576
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize <= maximumBytes else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    private static func decode<R: Request>(
        _ request: R,
        data: Data,
        response: HTTPURLResponse,
        decoder: JSONDecoder
    ) throws -> R.ReturnType {
        let hasSemanticallyEmptyBody = data.isEmpty
            || response.statusCode == 204
            || response.statusCode == 205

        if hasSemanticallyEmptyBody {
            if let emptyResponse = EmptyResponse() as? R.ReturnType {
                return emptyResponse
            }
            guard request.allowsEmptyResponseBody else {
                throw NetworkError.emptyResponse(statusCode: response.statusCode)
            }
        }

        return try request.decode(data, response: response, using: decoder)
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
    var allowsEmptyResponseBody: Bool { wrapped.allowsEmptyResponseBody }

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

    func customize(_ urlRequest: inout URLRequest) throws {
        try wrapped.customize(&urlRequest)
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
