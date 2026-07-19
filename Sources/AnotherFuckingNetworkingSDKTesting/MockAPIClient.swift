import Foundation
import AnotherFuckingNetworkingSDK

/// The kind of client operation captured by a mock invocation.
public enum MockRequestOperation: String, Equatable, Sendable {
    case request
    case page
    case stream
}

/// A structured, concurrency-safe record of a mock client invocation.
public struct RecordedRequest: Equatable, Sendable {
    public let sequenceID: Int
    public let operation: MockRequestOperation
    public let requestTypeID: ObjectIdentifier
    public let requestTypeName: String

    /// The request's declared HTTP method before final customization.
    public let method: HTTPMethod

    /// The final URL after custom URL construction and pagination are applied.
    public let url: URL

    /// The request's declared path before it is resolved against ``url``.
    public let path: String

    /// Query items from ``url``, including pagination items for page sends.
    public let queryItems: [URLQueryItem]

    /// Final request headers after ``Request/customize(_:)``, keyed by
    /// lowercase field name.
    public let headers: [String: String]

    /// Final in-memory body after ``Request/customize(_:)``.
    public let body: Data?
    public let page: Int?
    public let pageSize: Int?

    /// Creates a structured record of one mock client invocation.
    public init(
        sequenceID: Int,
        operation: MockRequestOperation,
        requestTypeID: ObjectIdentifier,
        requestTypeName: String,
        method: HTTPMethod,
        url: URL,
        path: String,
        queryItems: [URLQueryItem],
        headers: [String: String],
        body: Data?,
        page: Int?,
        pageSize: Int?
    ) {
        self.sequenceID = sequenceID
        self.operation = operation
        self.requestTypeID = requestTypeID
        self.requestTypeName = requestTypeName
        self.method = method
        self.url = url
        self.path = path
        self.queryItems = queryItems
        self.headers = headers
        self.body = body
        self.page = page
        self.pageSize = pageSize
    }
}

/// The upload or download operation captured by a mock transfer invocation.
public enum MockTransferOperation: Equatable, Sendable {
    case upload(UploadBody)
    case download(DownloadDestination)
}

/// A structured, concurrency-safe record of a mock file transfer.
public struct RecordedTransfer: Equatable, Sendable {
    public let sequenceID: Int
    public let operation: MockTransferOperation
    public let requestTypeID: ObjectIdentifier
    public let requestTypeName: String

    /// The request's declared method before final customization.
    public let method: HTTPMethod

    /// The final URL after custom URL construction and customization.
    public let url: URL

    /// The request's declared path before it is resolved against ``url``.
    public let path: String

    /// Query items from the final URL.
    public let queryItems: [URLQueryItem]

    /// Final request headers, keyed by lowercase field name.
    public let headers: [String: String]

    /// The final in-memory request body visible after customization.
    ///
    /// File uploads remain file-backed and initially expose `nil`; a request
    /// customization may still explicitly assign a body.
    public let requestBody: Data?

    public init(
        sequenceID: Int,
        operation: MockTransferOperation,
        requestTypeID: ObjectIdentifier,
        requestTypeName: String,
        method: HTTPMethod,
        url: URL,
        path: String,
        queryItems: [URLQueryItem],
        headers: [String: String],
        requestBody: Data?
    ) {
        self.sequenceID = sequenceID
        self.operation = operation
        self.requestTypeID = requestTypeID
        self.requestTypeName = requestTypeName
        self.method = method
        self.url = url
        self.path = path
        self.queryItems = queryItems
        self.headers = headers
        self.requestBody = requestBody
    }
}

/// An error produced when a mock cannot satisfy a recorded request.
public enum MockAPIClientError: LocalizedError, Equatable, Sendable {
    case missingStub(RecordedRequest)
    case responseTypeMismatch(RecordedRequest)

    public var errorDescription: String? {
        switch self {
        case .missingStub(let request):
            return "No \(request.operation.rawValue) stub is registered for \(request.requestTypeName) at \(request.path)."
        case .responseTypeMismatch(let request):
            return "The registered stub has the wrong response type for \(request.requestTypeName)."
        }
    }
}

/// An error produced when a mock cannot satisfy a transfer invocation.
public enum MockTransferError: LocalizedError, Equatable, Sendable {
    case missingStub(RecordedTransfer)
    case responseTypeMismatch(RecordedTransfer)

    public var errorDescription: String? {
        switch self {
        case .missingStub(let transfer):
            let operation: String
            switch transfer.operation {
            case .upload:
                operation = "upload"
            case .download:
                operation = "download"
            }
            return "No \(operation) stub is registered for \(transfer.requestTypeName) at \(transfer.path)."
        case .responseTypeMismatch(let transfer):
            return "The registered transfer stub has the wrong response type for \(transfer.requestTypeName)."
        }
    }
}

/// A deterministic, actor-isolated test double for the SDK's request,
/// streaming, and transfer protocols.
///
/// Exact request stubs take precedence over type-wide defaults. Request and
/// page operations have separate registries, and missing stubs always throw.
/// Stream stubs are finite in-memory byte sequences. Transfer stubs use
/// another independent registry and never read, create, move, replace, or
/// remove files. Type-wide stubs also match generic forwarding decorators such
/// as ``AuthenticatedAPIClient`` while exact stubs remain concrete.
public actor MockAPIClient: APIClientTransferProgressProtocol, APIClientStreamingProtocol {
    public typealias Sleeper = @Sendable (UInt64) async throws -> Void
    public typealias DownloadFactory = @Sendable (
        RecordedTransfer
    ) async throws -> DownloadResponse

    public private(set) var recordedRequests: [RecordedRequest] = []
    public private(set) var recordedTransfers: [RecordedTransfer] = []

    /// Path-only records retained for compatibility with simple assertions.
    public var calledRequests: [String] {
        recordedRequests.map { request in
            guard request.operation == .page, let page = request.page else {
                return request.path
            }
            return "\(request.path)?page=\(page)"
        }
    }

    private var stubs: [StubKey: Stub] = [:]
    private var transferStubs: [TransferStubKey: TransferStub] = [:]
    private var nextTransferSequenceID = 0
    private let baseURL: URL
    private let globalHeaders: [String: String]
    private let encoderFactory: APIClient.EncoderFactory
    private var delayNanoseconds: UInt64
    private let sleeper: Sleeper

    /// Creates a mock whose request construction mirrors a production client.
    ///
    /// - Parameters:
    ///   - baseURL: The URL used by request URL builders. Defaults to an
    ///     isolated `https://mock.invalid` origin.
    ///   - globalHeaders: Headers applied before request-specific overrides.
    ///   - encoderFactory: Creates the encoder used for matching and recording.
    ///   - delay: An optional simulated delay in seconds.
    ///   - sleeper: The wait implementation, injectable for deterministic tests.
    public init(
        baseURL: URL? = nil,
        globalHeaders: [String: String] = [:],
        encoderFactory: @escaping APIClient.EncoderFactory = { JSONEncoder() },
        delay: TimeInterval = 0,
        sleeper: @escaping Sleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.baseURL = baseURL ?? URL(string: "https://mock.invalid")!
        self.globalHeaders = globalHeaders
        self.encoderFactory = encoderFactory
        delayNanoseconds = Self.nanoseconds(for: delay)
        self.sleeper = sleeper
    }

    // MARK: Successful stubs

    public func stub<R: Request>(
        _ requestType: R.Type,
        with response: R.ReturnType
    ) {
        stubs[.type(requestType, operation: .request)] = .success(
            response,
            data: (response as? Data) ?? Data(),
            metadata: nil
        )
    }

    public func stub<R: Request>(
        _ request: R,
        with response: R.ReturnType
    ) throws {
        stubs[try exactKey(for: request, operation: .request)] = .success(
            response,
            data: (response as? Data) ?? Data(),
            metadata: nil
        )
    }

    public func stubPage<R: PaginatedRequest>(
        _ requestType: R.Type,
        with response: PaginatedResponse<R.ReturnType>
    ) {
        stubs[.type(requestType, operation: .page)] = .success(
            response,
            data: Data(),
            metadata: nil
        )
    }

    public func stubPage<R: PaginatedRequest>(
        _ request: R,
        with response: PaginatedResponse<R.ReturnType>
    ) throws {
        stubs[try exactKey(for: request, operation: .page)] = .success(
            response,
            data: Data(),
            metadata: nil
        )
    }

    /// Registers a response value together with deterministic HTTP metadata.
    public func stubResponse<R: Request>(
        _ requestType: R.Type,
        with response: HTTPResponse<R.ReturnType>
    ) {
        stubs[.type(requestType, operation: .request)] = .success(
            response.value,
            data: response.data,
            metadata: response.metadata
        )
    }

    /// Registers exact response metadata for one fully constructed request.
    public func stubResponse<R: Request>(
        _ request: R,
        with response: HTTPResponse<R.ReturnType>
    ) throws {
        stubs[try exactKey(for: request, operation: .request)] = .success(
            response.value,
            data: response.data,
            metadata: response.metadata
        )
    }

    /// Registers a paginated value together with deterministic HTTP metadata.
    public func stubPageResponse<R: PaginatedRequest>(
        _ requestType: R.Type,
        with response: HTTPResponse<PaginatedResponse<R.ReturnType>>
    ) {
        stubs[.type(requestType, operation: .page)] = .success(
            response.value,
            data: response.data,
            metadata: response.metadata
        )
    }

    /// Registers exact response metadata for one paginated request.
    public func stubPageResponse<R: PaginatedRequest>(
        _ request: R,
        with response: HTTPResponse<PaginatedResponse<R.ReturnType>>
    ) throws {
        stubs[try exactKey(for: request, operation: .page)] = .success(
            response.value,
            data: response.data,
            metadata: response.metadata
        )
    }

    /// Registers a finite byte stream for every request of the supplied type.
    /// The mock stream is intentionally in-memory and finite; production
    /// streaming behavior remains covered by URLSession transport tests.
    public func stubStream<R: HTTPRequest>(
        _ requestType: R.Type,
        data: Data,
        metadata: HTTPResponseMetadata = HTTPResponseMetadata(statusCode: 200)
    ) {
        stubs[.type(requestType, operation: .stream)] = .stream(
            data,
            metadata
        )
    }

    /// Registers a finite byte stream for one fully constructed request.
    public func stubStream<R: HTTPRequest>(
        _ request: R,
        data: Data,
        metadata: HTTPResponseMetadata = HTTPResponseMetadata(statusCode: 200)
    ) throws {
        stubs[try exactKey(for: request, operation: .stream)] = .stream(
            data,
            metadata
        )
    }

    // MARK: Failure stubs

    public func stubError<R: Request>(
        _ requestType: R.Type,
        error: any Error
    ) {
        stubs[.type(requestType, operation: .request)] = .failure(error)
    }

    public func stubError<R: Request>(
        _ request: R,
        error: any Error
    ) throws {
        stubs[try exactKey(for: request, operation: .request)] = .failure(error)
    }

    public func stubPageError<R: PaginatedRequest>(
        _ requestType: R.Type,
        error: any Error
    ) {
        stubs[.type(requestType, operation: .page)] = .failure(error)
    }

    public func stubPageError<R: PaginatedRequest>(
        _ request: R,
        error: any Error
    ) throws {
        stubs[try exactKey(for: request, operation: .page)] = .failure(error)
    }

    /// Registers a stream failure for every request of the supplied type.
    public func stubStreamError<R: HTTPRequest>(
        _ requestType: R.Type,
        error: any Error
    ) {
        stubs[.type(requestType, operation: .stream)] = .failure(error)
    }

    /// Registers a stream failure for one fully constructed request.
    public func stubStreamError<R: HTTPRequest>(
        _ request: R,
        error: any Error
    ) throws {
        stubs[try exactKey(for: request, operation: .stream)] = .failure(error)
    }

    // MARK: Upload stubs

    /// Registers a response for every upload request of the supplied type.
    public func stubUpload<R: Request>(
        _ requestType: R.Type,
        with response: HTTPResponse<R.ReturnType>
    ) {
        transferStubs[.type(requestType, kind: .upload)] = .uploadResponse(
            response
        )
    }

    /// Registers a response for one fully constructed upload and body source.
    public func stubUpload<R: Request>(
        _ request: R,
        from body: UploadBody,
        with response: HTTPResponse<R.ReturnType>
    ) throws {
        transferStubs[try exactTransferKey(
            for: request,
            operation: .upload(body)
        )] = .uploadResponse(response)
    }

    /// Registers a failure for every upload request of the supplied type.
    public func stubUploadError<R: Request>(
        _ requestType: R.Type,
        error: any Error
    ) {
        transferStubs[.type(requestType, kind: .upload)] = .failure(error)
    }

    /// Registers a failure for one fully constructed upload and body source.
    public func stubUploadError<R: Request>(
        _ request: R,
        from body: UploadBody,
        error: any Error
    ) throws {
        transferStubs[try exactTransferKey(
            for: request,
            operation: .upload(body)
        )] = .failure(error)
    }

    // MARK: Download stubs

    /// Registers one response for every download request of the supplied type.
    ///
    /// Use a factory when repeated temporary downloads should return distinct
    /// URLs.
    public func stubDownload<R: DownloadRequest>(
        _ requestType: R.Type,
        with response: DownloadResponse
    ) {
        transferStubs[.type(requestType, kind: .download)] = .downloadResponse(
            response
        )
    }

    /// Registers one response for an exact request and destination.
    public func stubDownload<R: DownloadRequest>(
        _ request: R,
        to destination: DownloadDestination,
        with response: DownloadResponse
    ) throws {
        transferStubs[try exactTransferKey(
            for: request,
            operation: .download(destination)
        )] = .downloadResponse(response)
    }

    /// Registers a factory that runs once for every matching download.
    public func stubDownload<R: DownloadRequest>(
        _ requestType: R.Type,
        using factory: @escaping DownloadFactory
    ) {
        transferStubs[.type(requestType, kind: .download)] = .downloadFactory(
            factory
        )
    }

    /// Registers a factory for one exact request and destination.
    public func stubDownload<R: DownloadRequest>(
        _ request: R,
        to destination: DownloadDestination,
        using factory: @escaping DownloadFactory
    ) throws {
        transferStubs[try exactTransferKey(
            for: request,
            operation: .download(destination)
        )] = .downloadFactory(factory)
    }

    /// Registers a failure for every download request of the supplied type.
    public func stubDownloadError<R: DownloadRequest>(
        _ requestType: R.Type,
        error: any Error
    ) {
        transferStubs[.type(requestType, kind: .download)] = .failure(error)
    }

    /// Registers a failure for one exact request and destination.
    public func stubDownloadError<R: DownloadRequest>(
        _ request: R,
        to destination: DownloadDestination,
        error: any Error
    ) throws {
        transferStubs[try exactTransferKey(
            for: request,
            operation: .download(destination)
        )] = .failure(error)
    }

    // MARK: Compatibility aliases

    public func mock<R: Request>(
        _ requestType: R.Type,
        with response: R.ReturnType
    ) {
        stub(requestType, with: response)
    }

    public func mock<R: Request>(
        _ request: R,
        with response: R.ReturnType
    ) throws {
        try stub(request, with: response)
    }

    public func mock<R: PaginatedRequest>(
        _ requestType: R.Type,
        with response: PaginatedResponse<R.ReturnType>
    ) {
        stubPage(requestType, with: response)
    }

    public func mock<R: PaginatedRequest>(
        _ request: R,
        with response: PaginatedResponse<R.ReturnType>
    ) throws {
        try stubPage(request, with: response)
    }

    public func mockError<R: Request>(
        _ requestType: R.Type,
        with error: any Error
    ) {
        stubError(requestType, error: error)
    }

    public func mockError<R: Request>(
        _ request: R,
        with error: any Error
    ) throws {
        try stubError(request, error: error)
    }

    // MARK: State management

    public func setDelay(_ delay: TimeInterval) {
        delayNanoseconds = Self.nanoseconds(for: delay)
    }

    public func clearStubs() {
        stubs.removeAll(keepingCapacity: true)
        transferStubs.removeAll(keepingCapacity: true)
    }

    public func clearRecordedRequests() {
        recordedRequests.removeAll(keepingCapacity: true)
    }

    public func clearRecordedTransfers() {
        recordedTransfers.removeAll(keepingCapacity: true)
    }

    public func reset() {
        clearStubs()
        clearRecordedRequests()
        clearRecordedTransfers()
        delayNanoseconds = 0
    }

    public func resetMocks() {
        reset()
    }

    // MARK: APIClientProtocol

    public func send<R: Request>(_ request: R) async throws -> R.ReturnType {
        try await sendResponse(request).value
    }

    public func sendResponse<R: Request>(
        _ request: R
    ) async throws -> HTTPResponse<R.ReturnType> {
        try Task.checkCancellation()
        let acceptedStatusCodes = request.acceptedStatusCodes
        let context = try makeContext(for: request, operation: .request)
        let invocation = record(request, operation: .request, context: context)
        let resolvedStub = resolve(
            R.self,
            operation: .request,
            signature: context.signature
        )
        let delay = delayNanoseconds

        try await wait(delay)

        guard let resolvedStub else {
            throw MockAPIClientError.missingStub(invocation)
        }

        switch resolvedStub {
        case .success(let value, let data, let metadata):
            guard let response = value as? R.ReturnType else {
                throw MockAPIClientError.responseTypeMismatch(invocation)
            }
            let responseMetadata = metadata ?? HTTPResponseMetadata(
                statusCode: 200,
                url: context.url
            )
            try Self.validateStatus(
                responseMetadata,
                data: data,
                acceptedStatusCodes: acceptedStatusCodes
            )
            return HTTPResponse(
                value: response,
                data: data,
                metadata: responseMetadata
            )
        case .failure(let error):
            throw error
        case .stream:
            throw MockAPIClientError.responseTypeMismatch(invocation)
        }
    }

    // MARK: APIClientStreamingProtocol

    public func stream<R: HTTPRequest>(
        _ request: R
    ) async throws -> HTTPByteStream {
        try Task.checkCancellation()
        let context = try makeContext(for: request, operation: .stream)
        let invocation = record(request, operation: .stream, context: context)
        let resolvedStub = resolve(
            R.self,
            operation: .stream,
            signature: context.signature
        )

        try await wait(delayNanoseconds)

        guard let resolvedStub else {
            throw MockAPIClientError.missingStub(invocation)
        }

        switch resolvedStub {
        case .stream(let data, let metadata):
            try Self.validateStatus(
                metadata,
                data: data,
                acceptedStatusCodes: request.acceptedStatusCodes
            )
            return HTTPByteStream(data: data, metadata: metadata)
        case .failure(let error):
            throw error
        case .success:
            throw MockAPIClientError.responseTypeMismatch(invocation)
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
        try Task.checkCancellation()
        let acceptedStatusCodes = request.acceptedStatusCodes
        let context = try makeContext(for: request, operation: .page)
        let invocation = record(request, operation: .page, context: context)
        let resolvedStub = resolve(
            R.self,
            operation: .page,
            signature: context.signature
        )
        let delay = delayNanoseconds

        try await wait(delay)

        guard let resolvedStub else {
            throw MockAPIClientError.missingStub(invocation)
        }

        switch resolvedStub {
        case .success(let value, let data, let metadata):
            guard let response = value as? PaginatedResponse<R.ReturnType> else {
                throw MockAPIClientError.responseTypeMismatch(invocation)
            }
            let responseMetadata = metadata ?? HTTPResponseMetadata(
                statusCode: 200,
                url: context.url
            )
            try Self.validateStatus(
                responseMetadata,
                data: data,
                acceptedStatusCodes: acceptedStatusCodes
            )
            return HTTPResponse(
                value: response,
                data: data,
                metadata: responseMetadata
            )
        case .failure(let error):
            throw error
        case .stream:
            throw MockAPIClientError.responseTypeMismatch(invocation)
        }
    }

    // MARK: APIClientTransferProtocol

    public func upload<R: Request>(
        _ request: R,
        from body: UploadBody
    ) async throws -> HTTPResponse<R.ReturnType> {
        try Task.checkCancellation()
        let acceptedStatusCodes = request.acceptedStatusCodes
        let operation = MockTransferOperation.upload(body)
        let context = try makeTransferContext(for: request, operation: operation)
        let invocation = recordTransfer(
            request,
            operation: operation,
            context: context
        )
        let resolvedStub = resolveTransfer(
            R.self,
            kind: .upload,
            signature: context.signature
        )
        let delay = delayNanoseconds

        try await wait(delay)

        guard let resolvedStub else {
            throw MockTransferError.missingStub(invocation)
        }

        switch resolvedStub {
        case .uploadResponse(let value):
            guard let response = value as? HTTPResponse<R.ReturnType> else {
                throw MockTransferError.responseTypeMismatch(invocation)
            }
            try Self.validateStatus(
                response.metadata,
                data: response.data,
                acceptedStatusCodes: acceptedStatusCodes
            )
            return response
        case .failure(let error):
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        case .downloadResponse, .downloadFactory:
            throw MockTransferError.responseTypeMismatch(invocation)
        }
    }

    public func upload<R: Request>(
        _ request: R,
        from body: UploadBody,
        progress: @escaping TransferProgressHandler
    ) async throws -> HTTPResponse<R.ReturnType> {
        let totalBytes: Int64?
        switch body {
        case .data(let data):
            totalBytes = Int64(data.count)
        case .file:
            totalBytes = nil
        }
        progress(TransferProgress(
            operation: .upload,
            phase: .started,
            bytesCompleted: 0,
            totalBytes: totalBytes
        ))
        do {
            let response = try await upload(request, from: body)
            progress(TransferProgress(
                operation: .upload,
                phase: .completed,
                bytesCompleted: totalBytes ?? 0,
                totalBytes: totalBytes
            ))
            return response
        } catch {
            progress(TransferProgress(
                operation: .upload,
                phase: Task.isCancelled || error is CancellationError
                    ? .cancelled
                    : .failed,
                bytesCompleted: 0,
                totalBytes: totalBytes
            ))
            throw error
        }
    }

    public func download<R: DownloadRequest>(
        _ request: R,
        to destination: DownloadDestination
    ) async throws -> DownloadResponse {
        try Task.checkCancellation()
        let acceptedStatusCodes = request.acceptedStatusCodes
        let operation = MockTransferOperation.download(destination)
        let context = try makeTransferContext(for: request, operation: operation)
        let invocation = recordTransfer(
            request,
            operation: operation,
            context: context
        )
        let resolvedStub = resolveTransfer(
            R.self,
            kind: .download,
            signature: context.signature
        )
        let delay = delayNanoseconds

        try await wait(delay)

        guard let resolvedStub else {
            throw MockTransferError.missingStub(invocation)
        }

        switch resolvedStub {
        case .downloadResponse(let response):
            try Task.checkCancellation()
            try Self.validateStatus(
                response.metadata,
                data: nil,
                acceptedStatusCodes: acceptedStatusCodes
            )
            return response
        case .downloadFactory(let factory):
            do {
                let response = try await factory(invocation)
                try Task.checkCancellation()
                try Self.validateStatus(
                    response.metadata,
                    data: nil,
                    acceptedStatusCodes: acceptedStatusCodes
                )
                return response
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                throw error
            }
        case .failure(let error):
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        case .uploadResponse:
            throw MockTransferError.responseTypeMismatch(invocation)
        }
    }

    public func download<R: DownloadRequest>(
        _ request: R,
        to destination: DownloadDestination,
        progress: @escaping TransferProgressHandler
    ) async throws -> DownloadResponse {
        progress(TransferProgress(
            operation: .download,
            phase: .started,
            bytesCompleted: 0
        ))
        do {
            let response = try await download(request, to: destination)
            let totalBytes = response.value(forHTTPHeaderField: "Content-Length")
                .flatMap(Int64.init)
            progress(TransferProgress(
                operation: .download,
                phase: .completed,
                bytesCompleted: totalBytes ?? 0,
                totalBytes: totalBytes
            ))
            return response
        } catch {
            progress(TransferProgress(
                operation: .download,
                phase: Task.isCancelled || error is CancellationError
                    ? .cancelled
                    : .failed,
                bytesCompleted: 0
            ))
            throw error
        }
    }

    private func wait(_ nanoseconds: UInt64) async throws {
        try Task.checkCancellation()
        if nanoseconds > 0 {
            try await sleeper(nanoseconds)
        }
        try Task.checkCancellation()
    }

    private func resolve<R: HTTPRequest>(
        _ requestType: R.Type,
        operation: MockRequestOperation,
        signature: Signature
    ) -> Stub? {
        stubs[.exact(requestType, operation: operation, signature: signature)]
            ?? stubs[.type(requestType, operation: operation)]
            ?? stubs.first { key, _ in
                key.operation == operation
                    && key.signature == nil
                    && Self.isWrappedRequestType(
                        registered: key.requestTypeName,
                        requested: String(reflecting: requestType)
                    )
            }?.value
    }

    private func exactKey<R: HTTPRequest>(
        for request: R,
        operation: MockRequestOperation
    ) throws -> StubKey {
        let context = try makeContext(for: request, operation: operation)
        return .exact(R.self, operation: operation, signature: context.signature)
    }

    private func resolveTransfer<R: HTTPRequest>(
        _ requestType: R.Type,
        kind: TransferKind,
        signature: TransferSignature
    ) -> TransferStub? {
        transferStubs[.exact(
            requestType,
            kind: kind,
            signature: signature
        )]
            ?? transferStubs[.type(requestType, kind: kind)]
            ?? transferStubs.first { key, _ in
                key.kind == kind
                    && key.signature == nil
                    && Self.isWrappedRequestType(
                        registered: key.requestTypeName,
                        requested: String(reflecting: requestType)
                    )
            }?.value
    }

    private func exactTransferKey<R: HTTPRequest>(
        for request: R,
        operation: MockTransferOperation
    ) throws -> TransferStubKey {
        let context = try makeTransferContext(
            for: request,
            operation: operation
        )
        return .exact(
            R.self,
            kind: operation.kind,
            signature: context.signature
        )
    }

    private func makeTransferContext<R: HTTPRequest>(
        for request: R,
        operation: MockTransferOperation
    ) throws -> TransferContext {
        switch operation {
        case .upload(.file(let url)) where !url.isFileURL:
            throw NetworkError.fileOperationFailed(
                FileTransferError.sourceIsNotFileURL(url)
            )
        case .download(.file(let url, _)) where !url.isFileURL:
            throw NetworkError.fileOperationFailed(
                FileTransferError.destinationIsNotFileURL(url)
            )
        default:
            break
        }

        guard let url = request.makeURL(baseURL: baseURL) else {
            throw NetworkError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue

        let headers = Self.mergingHeaders(
            defaults: globalHeaders,
            overrides: request.headers ?? [:]
        )
        for (name, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        switch operation {
        case .upload(.data(let data)):
            urlRequest.httpBody = data
        case .upload(.file):
            urlRequest.httpBody = nil
        case .download:
            do {
                urlRequest.httpBody = try request.makeBody(
                    using: encoderFactory()
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw NetworkError.encodingFailed(error)
            }
        }

        do {
            try request.customize(&urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NetworkError.requestConfigurationFailed(error)
        }

        guard let configuredURL = urlRequest.url else {
            throw NetworkError.invalidURL
        }

        return TransferContext(
            urlRequest: urlRequest,
            url: configuredURL,
            signature: TransferSignature(
                urlRequest: urlRequest,
                operation: operation
            )
        )
    }

    private func makeContext<R: HTTPRequest>(
        for request: R,
        operation: MockRequestOperation
    ) throws -> RequestContext {
        guard let url = finalURL(for: request, operation: operation) else {
            throw NetworkError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue

        let headers = Self.mergingHeaders(
            defaults: globalHeaders,
            overrides: request.headers ?? [:]
        )
        for (name, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        do {
            urlRequest.httpBody = try request.makeBody(using: encoderFactory())
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NetworkError.encodingFailed(error)
        }

        do {
            try request.customize(&urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NetworkError.requestConfigurationFailed(error)
        }

        guard let configuredURL = urlRequest.url else {
            throw NetworkError.invalidURL
        }

        return RequestContext(
            urlRequest: urlRequest,
            url: configuredURL,
            signature: Signature(request, urlRequest: urlRequest)
        )
    }

    private func finalURL<R: HTTPRequest>(
        for request: R,
        operation: MockRequestOperation
    ) -> URL? {
        guard let requestURL = request.makeURL(baseURL: baseURL) else {
            return nil
        }
        guard operation == .page,
              let paginated = request as? any PaginatedRequest,
              var components = URLComponents(
                url: requestURL,
                resolvingAgainstBaseURL: false
              ) else {
            return requestURL
        }

        let paginationNames = [paginated.pageQueryName, paginated.pageSizeQueryName]
        var queryItems = (components.queryItems ?? []).filter { item in
            !paginationNames.contains {
                $0.caseInsensitiveCompare(item.name) == .orderedSame
            }
        }
        queryItems.append(URLQueryItem(
            name: paginated.pageQueryName,
            value: String(paginated.page)
        ))
        queryItems.append(URLQueryItem(
            name: paginated.pageSizeQueryName,
            value: String(paginated.pageSize)
        ))
        components.queryItems = queryItems
        return components.url
    }

    @discardableResult
    private func record<R: HTTPRequest>(
        _ request: R,
        operation: MockRequestOperation,
        context: RequestContext
    ) -> RecordedRequest {
        let paginated = request as? any PaginatedRequest
        let invocation = RecordedRequest(
            sequenceID: recordedRequests.count,
            operation: operation,
            requestTypeID: ObjectIdentifier(R.self),
            requestTypeName: String(reflecting: R.self),
            method: request.method,
            url: context.url,
            path: request.path,
            queryItems: URLComponents(
                url: context.url,
                resolvingAgainstBaseURL: false
            )?.queryItems ?? [],
            headers: Self.normalizedHeaders(
                context.urlRequest.allHTTPHeaderFields ?? [:]
            ),
            body: context.body,
            page: paginated?.page,
            pageSize: paginated?.pageSize
        )
        recordedRequests.append(invocation)
        return invocation
    }

    @discardableResult
    private func recordTransfer<R: HTTPRequest>(
        _ request: R,
        operation: MockTransferOperation,
        context: TransferContext
    ) -> RecordedTransfer {
        let invocation = RecordedTransfer(
            sequenceID: nextTransferSequenceID,
            operation: operation,
            requestTypeID: ObjectIdentifier(R.self),
            requestTypeName: String(reflecting: R.self),
            method: request.method,
            url: context.url,
            path: request.path,
            queryItems: URLComponents(
                url: context.url,
                resolvingAgainstBaseURL: false
            )?.queryItems ?? [],
            headers: Self.normalizedHeaders(
                context.urlRequest.allHTTPHeaderFields ?? [:]
            ),
            requestBody: context.urlRequest.httpBody
        )
        nextTransferSequenceID += 1
        recordedTransfers.append(invocation)
        return invocation
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

    /// Decorators commonly wrap a request in a generic forwarding type (for
    /// example, the authenticated façade). Type-wide stubs continue to match
    /// that underlying request while exact stubs remain concrete.
    private static func isWrappedRequestType(
        registered: String,
        requested: String
    ) -> Bool {
        guard registered != requested else { return false }
        return requested.contains("<\(registered)>")
    }

    private static func validateStatus(
        _ metadata: HTTPResponseMetadata,
        data: Data?,
        acceptedStatusCodes: HTTPStatusPolicy
    ) throws {
        guard acceptedStatusCodes.accepts(metadata.statusCode) else {
            throw NetworkError.requestFailed(HTTPFailure(
                metadata: metadata,
                data: data
            ))
        }
    }

    private static func nanoseconds(for delay: TimeInterval) -> UInt64 {
        guard delay.isFinite, delay > 0 else { return 0 }
        let scaled = delay * 1_000_000_000
        guard scaled < Double(UInt64.max) else { return UInt64.max }
        return UInt64(scaled.rounded(.towardZero))
    }
}

private extension MockAPIClient {
    enum Stub: Sendable {
        case success(
            any Sendable,
            data: Data,
            metadata: HTTPResponseMetadata?
        )
        case stream(Data, HTTPResponseMetadata)
        case failure(any Error)
    }

    enum TransferStub: Sendable {
        case uploadResponse(any Sendable)
        case downloadResponse(DownloadResponse)
        case downloadFactory(DownloadFactory)
        case failure(any Error)
    }

    enum TransferKind: Hashable, Sendable {
        case upload
        case download
    }

    struct RequestContext: Sendable {
        let urlRequest: URLRequest
        let url: URL
        let signature: Signature

        var body: Data? { urlRequest.httpBody }
    }

    struct TransferContext: Sendable {
        let urlRequest: URLRequest
        let url: URL
        let signature: TransferSignature
    }

    struct StubKey: Hashable, Sendable {
        let operation: MockRequestOperation
        let requestType: ObjectIdentifier
        let requestTypeName: String
        let signature: Signature?

        static func type<R: HTTPRequest>(
            _ requestType: R.Type,
            operation: MockRequestOperation
        ) -> Self {
            Self(
                operation: operation,
                requestType: ObjectIdentifier(requestType),
                requestTypeName: String(reflecting: requestType),
                signature: nil
            )
        }

        static func exact<R: HTTPRequest>(
            _ requestType: R.Type,
            operation: MockRequestOperation,
            signature: Signature
        ) -> Self {
            Self(
                operation: operation,
                requestType: ObjectIdentifier(requestType),
                requestTypeName: String(reflecting: requestType),
                signature: signature
            )
        }
    }

    struct TransferStubKey: Hashable, Sendable {
        let kind: TransferKind
        let requestType: ObjectIdentifier
        let requestTypeName: String
        let signature: TransferSignature?

        static func type<R: HTTPRequest>(
            _ requestType: R.Type,
            kind: TransferKind
        ) -> Self {
            Self(
                kind: kind,
                requestType: ObjectIdentifier(requestType),
                requestTypeName: String(reflecting: requestType),
                signature: nil
            )
        }

        static func exact<R: HTTPRequest>(
            _ requestType: R.Type,
            kind: TransferKind,
            signature: TransferSignature
        ) -> Self {
            Self(
                kind: kind,
                requestType: ObjectIdentifier(requestType),
                requestTypeName: String(reflecting: requestType),
                signature: signature
            )
        }
    }

    struct Signature: Hashable, Sendable {
        let method: String?
        let url: String
        let headers: [KeyValue]
        let body: Data?
        let page: Int?
        let pageSize: Int?

        init<R: HTTPRequest>(_ request: R, urlRequest: URLRequest) {
            method = urlRequest.httpMethod
            url = urlRequest.url?.absoluteString ?? ""
            headers = (urlRequest.allHTTPHeaderFields ?? [:])
                .map { KeyValue(key: $0.key.lowercased(), value: $0.value) }
                .sorted()
            body = urlRequest.httpBody

            if let paginated = request as? any PaginatedRequest {
                page = paginated.page
                pageSize = paginated.pageSize
            } else {
                page = nil
                pageSize = nil
            }
        }
    }

    struct TransferSignature: Hashable, Sendable {
        let method: String?
        let url: String
        let headers: [KeyValue]
        let body: Data?
        let argument: TransferArgumentSignature

        init(
            urlRequest: URLRequest,
            operation: MockTransferOperation
        ) {
            method = urlRequest.httpMethod
            url = urlRequest.url?.absoluteString ?? ""
            headers = (urlRequest.allHTTPHeaderFields ?? [:])
                .map { KeyValue(key: $0.key.lowercased(), value: $0.value) }
                .sorted()
            body = urlRequest.httpBody

            switch operation {
            case .upload(.data(let data)):
                argument = .uploadData(data)
            case .upload(.file(let url)):
                argument = .uploadFile(url.absoluteString)
            case .download(.temporary):
                argument = .downloadTemporary
            case .download(.file(let url, let overwriteExisting)):
                argument = .downloadFile(
                    url.absoluteString,
                    overwriteExisting: overwriteExisting
                )
            }
        }
    }

    enum TransferArgumentSignature: Hashable, Sendable {
        case uploadData(Data)
        case uploadFile(String)
        case downloadTemporary
        case downloadFile(String, overwriteExisting: Bool)
    }

    struct KeyValue: Hashable, Comparable, Sendable {
        let key: String
        let value: String?

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.key != rhs.key {
                return lhs.key < rhs.key
            }
            return (lhs.value ?? "") < (rhs.value ?? "")
        }
    }
}

private extension MockTransferOperation {
    var kind: MockAPIClient.TransferKind {
        switch self {
        case .upload:
            return .upload
        case .download:
            return .download
        }
    }
}
