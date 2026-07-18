import Foundation

/// A provider for access tokens used by ``AuthenticatedAPIClient``.
public protocol HTTPAuthenticator: Sendable {
    /// Returns the current token, loading one when no valid token is cached.
    func accessToken() async throws -> String

    /// Forces one refresh. Concurrent refresh requests are expected to join
    /// the same in-flight operation rather than stampeding the identity
    /// service.
    func refreshToken() async throws -> String
}

/// Errors raised while loading or validating credentials.
public enum AuthenticationError: LocalizedError, Equatable, Sendable {
    case invalidToken

    public var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "The authentication provider returned an empty or expired token."
        }
    }
}

/// A token value together with its optional expiration instant.
public struct AccessToken: Equatable, Sendable {
    public let value: String
    public let expiration: Date?

    public init(value: String, expiration: Date? = nil) {
        self.value = value
        self.expiration = expiration
    }

    fileprivate func isValid(at date: Date) -> Bool {
        !value.isEmpty && (expiration == nil || expiration! > date)
    }
}

/// An actor-backed token provider that coalesces concurrent loads and
/// refreshes into one task.
public actor SingleFlightTokenProvider: HTTPAuthenticator {
    public typealias Loader = @Sendable () async throws -> AccessToken

    private let loader: Loader
    private let refreshLoader: Loader
    private let now: @Sendable () -> Date
    private var cachedToken: AccessToken?
    private var inFlight: Task<AccessToken, Error>?

    public init(
        loader: @escaping Loader,
        refreshLoader: @escaping Loader,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.loader = loader
        self.refreshLoader = refreshLoader
        self.now = now
    }

    public func accessToken() async throws -> String {
        try await token(forceRefresh: false).value
    }

    public func refreshToken() async throws -> String {
        try await token(forceRefresh: true).value
    }

    private func token(forceRefresh: Bool) async throws -> AccessToken {
        if !forceRefresh, let cachedToken, cachedToken.isValid(at: now()) {
            return cachedToken
        }

        if let inFlight {
            return try await inFlight.value
        }

        let selectedLoader = forceRefresh ? refreshLoader : loader
        let task = Task { try await selectedLoader() }
        inFlight = task
        do {
            let token = try await task.value
            guard token.isValid(at: now()) else {
                inFlight = nil
                throw AuthenticationError.invalidToken
            }
            cachedToken = token
            inFlight = nil
            return token
        } catch {
            inFlight = nil
            throw error
        }
    }
}

/// An authenticated façade over a transfer-capable API client.
///
/// A request receives an `Authorization: Bearer ...` header after its own
/// final customization. If the server rejects that request with HTTP 401, the
/// façade refreshes once and replays the original typed request when its
/// authentication replay policy permits it. Idempotent methods are allowed by
/// default; mutation methods must explicitly opt in.
public struct AuthenticatedAPIClient<
    BaseClient: APIClientTransferProtocol & APIClientStreamingProtocol,
    Authenticator: HTTPAuthenticator
>: APIClientTransferProtocol, APIClientStreamingProtocol {
    private let baseClient: BaseClient
    private let authenticator: Authenticator

    public init(
        client: BaseClient,
        authenticator: Authenticator
    ) {
        baseClient = client
        self.authenticator = authenticator
    }

    public func send<R: Request>(_ request: R) async throws -> R.ReturnType {
        try await sendResponse(request).value
    }

    public func sendResponse<R: Request>(
        _ request: R
    ) async throws -> HTTPResponse<R.ReturnType> {
        var token = try await authenticator.accessToken()
        do {
            return try await baseClient.sendResponse(
                AuthenticatedHTTPRequest(request: request, token: token)
            )
        } catch {
            guard Self.shouldRefresh(after: error), Self.canReplay(request) else {
                throw error
            }
            token = try await authenticator.refreshToken()
            return try await baseClient.sendResponse(
                AuthenticatedHTTPRequest(request: request, token: token)
            )
        }
    }

    public func sendPage<R: PaginatedRequest>(
        _ request: R
    ) async throws -> PaginatedResponse<R.ReturnType> {
        try await sendPageResponse(request).value
    }

    public func sendPageResponse<R: PaginatedRequest>(
        _ request: R
    ) async throws -> HTTPResponse<PaginatedResponse<R.ReturnType>> {
        var token = try await authenticator.accessToken()
        do {
            return try await baseClient.sendPageResponse(
                AuthenticatedPaginatedRequest(request: request, token: token)
            )
        } catch {
            guard Self.shouldRefresh(after: error), Self.canReplay(request) else {
                throw error
            }
            token = try await authenticator.refreshToken()
            return try await baseClient.sendPageResponse(
                AuthenticatedPaginatedRequest(request: request, token: token)
            )
        }
    }

    public func upload<R: Request>(
        _ request: R,
        from body: UploadBody
    ) async throws -> HTTPResponse<R.ReturnType> {
        var token = try await authenticator.accessToken()
        do {
            return try await baseClient.upload(
                AuthenticatedHTTPRequest(request: request, token: token),
                from: body
            )
        } catch {
            guard Self.shouldRefresh(after: error), Self.canReplay(request) else {
                throw error
            }
            token = try await authenticator.refreshToken()
            return try await baseClient.upload(
                AuthenticatedHTTPRequest(request: request, token: token),
                from: body
            )
        }
    }

    public func download<R: DownloadRequest>(
        _ request: R,
        to destination: DownloadDestination
    ) async throws -> DownloadResponse {
        var token = try await authenticator.accessToken()
        do {
            return try await baseClient.download(
                AuthenticatedHTTPRequest(request: request, token: token),
                to: destination
            )
        } catch {
            guard Self.shouldRefresh(after: error), Self.canReplay(request) else {
                throw error
            }
            token = try await authenticator.refreshToken()
            return try await baseClient.download(
                AuthenticatedHTTPRequest(request: request, token: token),
                to: destination
            )
        }
    }

    public func stream<R: HTTPRequest>(
        _ request: R
    ) async throws -> HTTPByteStream {
        var token = try await authenticator.accessToken()
        do {
            return try await baseClient.stream(
                AuthenticatedHTTPRequest(request: request, token: token)
            )
        } catch {
            guard Self.shouldRefresh(after: error), Self.canReplay(request) else {
                throw error
            }
            token = try await authenticator.refreshToken()
            return try await baseClient.stream(
                AuthenticatedHTTPRequest(request: request, token: token)
            )
        }
    }

    private static func shouldRefresh(after error: any Error) -> Bool {
        guard case .requestFailed(let failure) = error as? NetworkError else {
            return false
        }
        return failure.statusCode == 401
    }

    private static func canReplay<R: HTTPRequest>(_ request: R) -> Bool {
        switch request.authenticationReplaySafety {
        case .explicitlyReplayable:
            return true
        case .idempotentMethodsOnly:
            return [
                HTTPMethod.get,
                .head,
                .put,
                .delete,
                .options
            ].contains(request.method)
        }
    }
}

private struct AuthenticatedHTTPRequest<Base: HTTPRequest>: HTTPRequest {
    let request: Base
        let token: String

    var path: String { request.path }
    var pathEncoding: RequestPathEncoding { request.pathEncoding }
    var method: HTTPMethod { request.method }
    var queryItems: [URLQueryItem]? { request.queryItems }
    var body: Data? { request.body }
    var headers: [String: String]? { request.headers }
    var acceptedStatusCodes: HTTPStatusPolicy { request.acceptedStatusCodes }
    var retryPolicy: HTTPRetryPolicy { request.retryPolicy }
    var authenticationReplaySafety: HTTPRetryPolicy.ReplaySafety {
        request.authenticationReplaySafety
    }

    func makeURL(baseURL: URL) -> URL? {
        request.makeURL(baseURL: baseURL)
    }

    func makeBody(using encoder: JSONEncoder) throws -> Data? {
        try request.makeBody(using: encoder)
    }

    func customize(_ urlRequest: inout URLRequest) throws {
        try request.customize(&urlRequest)
        urlRequest.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
    }
}

extension AuthenticatedHTTPRequest: Request where Base: Request {
    typealias ReturnType = Base.ReturnType

    var allowsEmptyResponseBody: Bool { request.allowsEmptyResponseBody }

    func decode(
        _ data: Data,
        response: HTTPURLResponse,
        using decoder: JSONDecoder
    ) throws -> Base.ReturnType {
        try request.decode(data, response: response, using: decoder)
    }
}

extension AuthenticatedHTTPRequest: DownloadRequest where Base: DownloadRequest {}

extension AuthenticatedAPIClient: APIClientTransferProgressProtocol
where BaseClient: APIClientTransferProgressProtocol {
    public func upload<R: Request>(
        _ request: R,
        from body: UploadBody,
        progress: @escaping TransferProgressHandler
    ) async throws -> HTTPResponse<R.ReturnType> {
        var token = try await authenticator.accessToken()
        do {
            return try await baseClient.upload(
                AuthenticatedHTTPRequest(request: request, token: token),
                from: body,
                progress: progress
            )
        } catch {
            guard Self.shouldRefresh(after: error), Self.canReplay(request) else {
                throw error
            }
            token = try await authenticator.refreshToken()
            return try await baseClient.upload(
                AuthenticatedHTTPRequest(request: request, token: token),
                from: body,
                progress: progress
            )
        }
    }

    public func download<R: DownloadRequest>(
        _ request: R,
        to destination: DownloadDestination,
        progress: @escaping TransferProgressHandler
    ) async throws -> DownloadResponse {
        var token = try await authenticator.accessToken()
        do {
            return try await baseClient.download(
                AuthenticatedHTTPRequest(request: request, token: token),
                to: destination,
                progress: progress
            )
        } catch {
            guard Self.shouldRefresh(after: error), Self.canReplay(request) else {
                throw error
            }
            token = try await authenticator.refreshToken()
            return try await baseClient.download(
                AuthenticatedHTTPRequest(request: request, token: token),
                to: destination,
                progress: progress
            )
        }
    }
}

private struct AuthenticatedPaginatedRequest<Base: PaginatedRequest>: PaginatedRequest {
    typealias ReturnType = Base.ReturnType

    let request: Base
    let token: String

    var path: String { request.path }
    var pathEncoding: RequestPathEncoding { request.pathEncoding }
    var method: HTTPMethod { request.method }
    var queryItems: [URLQueryItem]? { request.queryItems }
    var body: Data? { request.body }
    var headers: [String: String]? { request.headers }
    var acceptedStatusCodes: HTTPStatusPolicy { request.acceptedStatusCodes }
    var retryPolicy: HTTPRetryPolicy { request.retryPolicy }
    var authenticationReplaySafety: HTTPRetryPolicy.ReplaySafety {
        request.authenticationReplaySafety
    }
    var page: Int { request.page }
    var pageSize: Int { request.pageSize }
    var pageQueryName: String { request.pageQueryName }
    var pageSizeQueryName: String { request.pageSizeQueryName }
    var allowsEmptyResponseBody: Bool { request.allowsEmptyResponseBody }

    func makeURL(baseURL: URL) -> URL? {
        request.makeURL(baseURL: baseURL)
    }

    func makeBody(using encoder: JSONEncoder) throws -> Data? {
        try request.makeBody(using: encoder)
    }

    func customize(_ urlRequest: inout URLRequest) throws {
        try request.customize(&urlRequest)
        urlRequest.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
    }

    func decode(
        _ data: Data,
        response: HTTPURLResponse,
        using decoder: JSONDecoder
    ) throws -> Base.ReturnType {
        try request.decode(data, response: response, using: decoder)
    }

    func decodePage(
        _ data: Data,
        response: HTTPURLResponse,
        using decoder: JSONDecoder
    ) throws -> PaginatedResponse<Base.ReturnType> {
        try request.decodePage(data, response: response, using: decoder)
    }
}
