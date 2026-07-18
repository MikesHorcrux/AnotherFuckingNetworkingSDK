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

/// A client capable of exposing successful HTTP response bodies as a
/// single-pass byte stream.
public protocol APIClientStreamingProtocol: Sendable {
    func stream<R: HTTPRequest>(_ request: R) async throws -> HTTPByteStream
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

/// A transfer-capable client that reports upload and download byte progress.
public protocol APIClientTransferProgressProtocol: APIClientTransferProtocol {
    func upload<R: Request>(
        _ request: R,
        from body: UploadBody,
        progress: @escaping TransferProgressHandler
    ) async throws -> HTTPResponse<R.ReturnType>

    func download<R: DownloadRequest>(
        _ request: R,
        to destination: DownloadDestination,
        progress: @escaping TransferProgressHandler
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

package struct WebSocketTransportConfiguration: Sendable {
    package let maximumMessageSize: Int?
    package let inboundBufferingPolicy: WebSocketInboundBufferingPolicy
}

typealias WebSocketTransportFactory = @Sendable (
    URLSession,
    URLRequest,
    WebSocketTransportConfiguration
) -> any WebSocketTransport

typealias DownloadOperation = @Sendable (
    URLRequest
) async throws -> (URL, URLResponse)
typealias DownloadOperationWithDelegate = @Sendable (
    URLRequest,
    URLSessionTaskDelegate?
) async throws -> (URL, URLResponse)

typealias RetrySleeper = @Sendable (UInt64) async throws -> Void
typealias RetryNowProvider = @Sendable () -> Date
typealias RetryRandomProvider = @Sendable () -> Double

private final class TransferProgressDelegate: NSObject,
    URLSessionTaskDelegate,
    URLSessionDownloadDelegate,
    @unchecked Sendable {
    private let operation: TransferProgressOperation
    private let attempt: Int
    private let handler: TransferProgressHandler
    private let state: CriticalState<TransferProgress>

    init(
        operation: TransferProgressOperation,
        attempt: Int,
        handler: @escaping TransferProgressHandler
    ) {
        self.operation = operation
        self.attempt = attempt
        self.handler = handler
        state = CriticalState(TransferProgress(
            operation: operation,
            phase: .started,
            bytesCompleted: 0,
            attempt: attempt
        ))
    }

    var latest: TransferProgress {
        state.withCriticalRegion { $0 }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        emit(
            phase: .running,
            bytesCompleted: totalBytesSent,
            totalBytes: totalBytesExpectedToSend
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        emit(
            phase: .running,
            bytesCompleted: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}

    func emit(
        phase: TransferProgressPhase,
        bytesCompleted: Int64,
        totalBytes: Int64? = nil
    ) {
        let event = TransferProgress(
            operation: operation,
            phase: phase,
            bytesCompleted: bytesCompleted,
            totalBytes: totalBytes,
            attempt: attempt
        )
        state.withCriticalRegion { $0 = event }
        handler(event)
    }
}

/// A URLSession-backed API client.
///
/// Configuration mutations are synchronized. Each request takes one atomic
/// configuration snapshot before doing any work, so an in-flight request never
/// observes a partially updated base URL, header set, or codec configuration.
public final class APIClient: APIClientTransferProgressProtocol, APIClientStreamingProtocol, WebSocketClientProtocol, Sendable {
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
        get { state.withCriticalRegion { $0 } }
        set { state.withCriticalRegion { $0 = newValue } }
    }

    /// The root URL used to resolve request paths.
    public var baseURL: URL? {
        get { state.withCriticalRegion { $0.baseURL } }
        set { state.withCriticalRegion { $0.baseURL = newValue } }
    }

    /// Headers applied to every request unless overridden by a request header.
    public var globalHeaders: [String: String] {
        get { state.withCriticalRegion { $0.globalHeaders } }
        set { state.withCriticalRegion { $0.globalHeaders = newValue } }
    }

    private let state: CriticalState<Configuration>
    private let urlSession: URLSession
    private let logger: NetworkingLogger?
    private let activityMonitor: NetworkActivityMonitor?
    private let telemetry: NetworkTelemetry?
    private let telemetrySequence = CriticalState(UInt64(0))
    private let fileIOExecutor: FileIOExecutor
    private let downloadOperationWithDelegate: DownloadOperationWithDelegate
    private let retrySleeper: RetrySleeper
    private let retryNow: RetryNowProvider
    private let retryRandom: RetryRandomProvider
    private let webSocketTransportFactory: WebSocketTransportFactory

    public convenience init(
        baseURL: URL? = nil,
        urlSession: URLSession = .shared,
        globalHeaders: [String: String] = [:],
        encoderFactory: @escaping EncoderFactory = { JSONEncoder() },
        decoderFactory: @escaping DecoderFactory = { JSONDecoder() },
        logger: NetworkingLogger? = nil,
        activityMonitor: NetworkActivityMonitor? = nil,
        telemetry: NetworkTelemetry? = nil
    ) {
        self.init(
            baseURL: baseURL,
            urlSession: urlSession,
            globalHeaders: globalHeaders,
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory,
            logger: logger,
            activityMonitor: activityMonitor,
            telemetry: telemetry,
            webSocketTransportFactory: { session, request, configuration in
                URLSessionWebSocketTransport(
                    session: session,
                    request: request,
                    maximumMessageSize: configuration.maximumMessageSize,
                    inboundBufferingPolicy:
                        configuration.inboundBufferingPolicy
                )
            }
        )
    }

    init(
        baseURL: URL? = nil,
        urlSession: URLSession = .shared,
        globalHeaders: [String: String] = [:],
        encoderFactory: @escaping EncoderFactory = { JSONEncoder() },
        decoderFactory: @escaping DecoderFactory = { JSONDecoder() },
        logger: NetworkingLogger? = nil,
        activityMonitor: NetworkActivityMonitor? = nil,
        telemetry: NetworkTelemetry? = nil,
        fileIOExecutor: FileIOExecutor = .shared,
        downloadOperation: DownloadOperation? = nil,
        retrySleeper: @escaping RetrySleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        retryNow: @escaping RetryNowProvider = { Date() },
        retryRandom: @escaping RetryRandomProvider = {
            Double.random(in: 0...1)
        },
        webSocketTransportFactory: @escaping WebSocketTransportFactory
    ) {
        state = CriticalState(
            Configuration(
                baseURL: baseURL,
                globalHeaders: globalHeaders,
                encoderFactory: encoderFactory,
                decoderFactory: decoderFactory
            )
        )
        self.urlSession = urlSession
        self.logger = logger
        self.activityMonitor = activityMonitor
        self.telemetry = telemetry
        self.fileIOExecutor = fileIOExecutor
        self.downloadOperationWithDelegate = { request, delegate in
            if let downloadOperation {
                return try await downloadOperation(request)
            }
            return try await urlSession.download(
                for: request,
                delegate: delegate
            )
        }
        self.retrySleeper = retrySleeper
        self.retryNow = retryNow
        self.retryRandom = retryRandom
        self.webSocketTransportFactory = webSocketTransportFactory
    }

    /// Atomically updates multiple configuration values.
    public func updateConfiguration(
        _ update: @Sendable (inout Configuration) -> Void
    ) {
        state.withCriticalRegion(update)
    }

    private func beginTelemetry(
        _ kind: NetworkOperationKind
    ) -> NetworkTelemetryContext? {
        guard let telemetry else { return nil }
        let operationID = telemetrySequence.withCriticalRegion { value in
            let current = value
            value &+= 1
            return current
        }
        let context = NetworkTelemetryContext(
            telemetry: telemetry,
            operationID: operationID,
            kind: kind
        )
        context.emit(phase: .started)
        return context
    }

    private func finishTelemetry(
        _ context: NetworkTelemetryContext?,
        statusCode: Int? = nil,
        bytesSent: Int64? = nil,
        bytesReceived: Int64? = nil,
        error: (any Error)? = nil
    ) {
        guard let context else { return }
        if let error {
            let phase: NetworkTelemetryPhase =
                error is CancellationError || Task.isCancelled
                    ? .cancelled
                    : .failed
            context.emit(
                phase: phase,
                statusCode: statusCode,
                bytesSent: bytesSent,
                bytesReceived: bytesReceived,
                errorKind: phase == .failed
                    ? networkTelemetryErrorKind(error)
                    : nil,
                durationNanoseconds: context.elapsedNanoseconds()
            )
        } else {
            context.emit(
                phase: .succeeded,
                statusCode: statusCode,
                bytesSent: bytesSent,
                bytesReceived: bytesReceived,
                durationNanoseconds: context.elapsedNanoseconds()
            )
        }
    }

    private static func uploadByteCount(_ body: UploadBody) -> Int64? {
        switch body {
        case .data(let data):
            return Int64(data.count)
        case .file:
            return nil
        case .multipart(let form):
            return form.estimatedByteCount
        }
    }

    /// Opens a WebSocket after its HTTP upgrade handshake succeeds.
    ///
    /// The connection uses the same base URL, global headers, cookies,
    /// authentication challenges, and URL session as ordinary requests.
    public func connect<R: WebSocketRequest>(
        _ request: R
    ) async throws -> any WebSocketConnectionProtocol {
        let telemetryContext = beginTelemetry(.webSocketHandshake)
        do {
            let connection: any WebSocketConnectionProtocol
            if let activityMonitor {
                connection = try await activityMonitor.track(.webSocketHandshake) {
                    try await self.connectWithoutMonitoring(request)
                }
            } else {
                connection = try await connectWithoutMonitoring(request)
            }
            finishTelemetry(telemetryContext)
            return connection
        } catch {
            finishTelemetry(telemetryContext, error: error)
            throw error
        }
    }

    private func connectWithoutMonitoring<R: WebSocketRequest>(
        _ request: R
    ) async throws -> any WebSocketConnectionProtocol {
        try Task.checkCancellation()
        let configuration = state.withCriticalRegion { $0 }
        let preparedRequest = try WebSocketRequestBuilder.prepare(
            request,
            baseURL: configuration.baseURL,
            globalHeaders: configuration.globalHeaders
        )
        let urlRequest = preparedRequest.urlRequest
        try Task.checkCancellation()
        guard let url = urlRequest.url else {
            throw WebSocketError.invalidURL
        }

        logger?.log(request: urlRequest)
        let transport = webSocketTransportFactory(
            urlSession,
            urlRequest,
            preparedRequest.transportConfiguration
        )

        do {
            let negotiatedSubprotocol = try await transport.open()
            try Task.checkCancellation()
            return WebSocketConnection(
                url: url,
                negotiatedSubprotocol: negotiatedSubprotocol,
                transport: transport
            )
        } catch {
            if Task.isCancelled || error is CancellationError {
                transport.cancel()
                throw CancellationError()
            }
            if let error = error as? WebSocketError {
                throw error
            }
            if let error = error as? URLError {
                throw WebSocketError.transport(error)
            }
            throw WebSocketError.unknown(error)
        }
    }

    /// Sends a request and decodes its declared response type.
    public func send<R: Request>(_ request: R) async throws -> R.ReturnType {
        try await sendResponse(request).value
    }

    /// Opens a single-pass byte stream for an HTTP response.
    ///
    /// Status validation and retry decisions happen before the stream is
    /// returned. Once a successful stream is returned, its bytes are exposed
    /// exactly once and no retry can replay a partially consumed response.
    /// Failed responses retain at most one mebibyte of body data in their
    /// ``HTTPFailure`` value.
    public func stream<R: HTTPRequest>(_ request: R) async throws -> HTTPByteStream {
        let telemetryContext = beginTelemetry(.stream)
        let telemetryFinish = telemetryContext?.beginLease()
        do {
            let finish: (@Sendable (NetworkActivityOutcome) -> Void)?
            if let activityMonitor {
                let activityFinish = activityMonitor.beginLease(.stream)
                finish = { outcome in
                    activityFinish(outcome)
                    telemetryFinish?(outcome)
                }
            } else {
                finish = telemetryFinish
            }
            return try await streamWithoutMonitoring(
                request,
                finish: finish,
                telemetry: telemetryContext
            )
        } catch {
            telemetryFinish?(
                Task.isCancelled || error is CancellationError
                    ? .cancelled
                    : .failed
            )
            throw error
        }
    }

    private func streamWithoutMonitoring<R: HTTPRequest>(
        _ request: R,
        finish: (@Sendable (NetworkActivityOutcome) -> Void)?,
        telemetry: NetworkTelemetryContext?
    ) async throws -> HTTPByteStream {
        try Task.checkCancellation()
        let acceptedStatusCodes = request.acceptedStatusCodes
        let retryPolicy = request.retryPolicy
        let configuration = state.withCriticalRegion { $0 }
        let urlRequest = try Self.makeURLRequest(
            request,
            configuration: configuration
        )

        var attempt = 1
        while true {
            try Task.checkCancellation()
            logger?.log(request: urlRequest)
            let telemetryAttemptStartedAt = DispatchTime.now().uptimeNanoseconds
            telemetry?.emit(phase: .attemptStarted, attempt: attempt)

            let bytes: URLSession.AsyncBytes
            let response: URLResponse
            do {
                (bytes, response) = try await urlSession.bytes(for: urlRequest)
            } catch {
                let networkError = try Self.mappedTransportError(error)
                telemetry?.emit(
                    phase: .attemptFailed,
                    attempt: attempt,
                    errorKind: networkTelemetryErrorKind(networkError),
                    durationNanoseconds: telemetry?.attemptElapsed(
                        since: telemetryAttemptStartedAt
                    )
                )
                try Task.checkCancellation()
                let retryDelay: UInt64?
                if case .transport(let urlError) = networkError {
                    retryDelay = retryPolicy.retryDelayNanoseconds(
                        afterAttempt: attempt,
                        method: urlRequest.httpMethod ?? "",
                        failure: .transport(urlError),
                        now: retryNow(),
                        randomUnitValue: retryRandom()
                    )
                } else {
                    retryDelay = nil
                }

                guard let delay = retryDelay else {
                    throw networkError
                }
                logger?.logRetry(
                    nextAttempt: attempt + 1,
                    delayNanoseconds: delay
                )
                try await waitBeforeRetry(delay)
                attempt += 1
                continue
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                bytes.task.cancel()
                telemetry?.emit(
                    phase: .attemptFailed,
                    attempt: attempt,
                    errorKind: .invalidResponse,
                    durationNanoseconds: telemetry?.attemptElapsed(
                        since: telemetryAttemptStartedAt
                    )
                )
                finish?(.failed)
                throw NetworkError.invalidResponse
            }

            let metadata = HTTPResponseMetadata(httpResponse)
            guard acceptedStatusCodes.accepts(httpResponse.statusCode) else {
                telemetry?.emit(
                    phase: .attemptFailed,
                    attempt: attempt,
                    statusCode: httpResponse.statusCode,
                    errorKind: .httpStatus,
                    durationNanoseconds: telemetry?.attemptElapsed(
                        since: telemetryAttemptStartedAt
                    )
                )
                let failure = HTTPFailure(metadata: metadata)
                let retryDelay = retryPolicy.retryDelayNanoseconds(
                    afterAttempt: attempt,
                    method: urlRequest.httpMethod ?? "",
                    failure: .response(failure),
                    now: retryNow(),
                    randomUnitValue: retryRandom()
                )

                if let delay = retryDelay {
                    bytes.task.cancel()
                    logger?.logRetry(
                        nextAttempt: attempt + 1,
                        delayNanoseconds: delay
                    )
                    try await waitBeforeRetry(delay)
                    attempt += 1
                    continue
                }

                let errorData = await Self.readStreamErrorData(bytes)
                bytes.task.cancel()
                finish?(.failed)
                throw NetworkError.requestFailed(
                    HTTPFailure(metadata: metadata, data: errorData)
                )
            }

            telemetry?.emit(
                phase: .attemptCompleted,
                attempt: attempt,
                statusCode: httpResponse.statusCode,
                durationNanoseconds: telemetry?.attemptElapsed(
                    since: telemetryAttemptStartedAt
                )
            )

            return HTTPByteStream(
                bytes: bytes,
                metadata: metadata,
                finish: finish
            )
        }
    }

    /// Sends a request and returns its decoded value with HTTP metadata.
    public func sendResponse<R: Request>(
        _ request: R
    ) async throws -> HTTPResponse<R.ReturnType> {
        guard let activityMonitor else {
            return try await sendResponseWithoutMonitoring(request)
        }
        return try await activityMonitor.track(.request) {
            try await self.sendResponseWithoutMonitoring(request)
        }
    }

    private func sendResponseWithoutMonitoring<R: Request>(
        _ request: R
    ) async throws -> HTTPResponse<R.ReturnType> {
        try Task.checkCancellation()
        let telemetryContext = beginTelemetry(.request)
        do {
            let acceptedStatusCodes = request.acceptedStatusCodes
            let retryPolicy = request.retryPolicy
            let configuration = state.withCriticalRegion { $0 }
            let urlRequest = try Self.makeURLRequest(
                request,
                configuration: configuration
            )
            let (data, httpResponse) = try await performDataRequest(
                urlRequest,
                acceptedStatusCodes: acceptedStatusCodes,
                retryPolicy: retryPolicy,
                telemetry: telemetryContext
            ) {
                try await self.urlSession.data(for: urlRequest)
            }
            let result = try Self.makeResponse(
                request,
                data: data,
                response: httpResponse,
                configuration: configuration
            )
            finishTelemetry(
                telemetryContext,
                statusCode: httpResponse.statusCode,
                bytesReceived: Int64(data.count)
            )
            return result
        } catch {
            finishTelemetry(telemetryContext, error: error)
            throw error
        }
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
        let telemetryContext = beginTelemetry(.upload)
        do {
            let response: HTTPResponse<R.ReturnType>
            if let activityMonitor {
                response = try await activityMonitor.track(.upload) {
                    try await self.uploadWithoutMonitoring(
                        request,
                        from: body,
                        progress: nil,
                        telemetry: telemetryContext
                    )
                }
            } else {
                response = try await uploadWithoutMonitoring(
                    request,
                    from: body,
                    progress: nil,
                    telemetry: telemetryContext
                )
            }
            finishTelemetry(
                telemetryContext,
                statusCode: response.statusCode,
                bytesSent: Self.uploadByteCount(body),
                bytesReceived: Int64(response.data.count)
            )
            return response
        } catch {
            finishTelemetry(telemetryContext, error: error)
            throw error
        }
    }

    /// Uploads bytes while reporting opt-in byte and lifecycle progress.
    public func upload<R: Request>(
        _ request: R,
        from body: UploadBody,
        progress: @escaping TransferProgressHandler
    ) async throws -> HTTPResponse<R.ReturnType> {
        let telemetryContext = beginTelemetry(.upload)
        do {
            let response: HTTPResponse<R.ReturnType>
            if let activityMonitor {
                response = try await activityMonitor.track(.upload) {
                    try await self.uploadWithoutMonitoring(
                        request,
                        from: body,
                        progress: progress,
                        telemetry: telemetryContext
                    )
                }
            } else {
                response = try await uploadWithoutMonitoring(
                    request,
                    from: body,
                    progress: progress,
                    telemetry: telemetryContext
                )
            }
            finishTelemetry(
                telemetryContext,
                statusCode: response.statusCode,
                bytesSent: Self.uploadByteCount(body),
                bytesReceived: Int64(response.data.count)
            )
            return response
        } catch {
            finishTelemetry(telemetryContext, error: error)
            throw error
        }
    }

    private func uploadWithoutMonitoring<R: Request>(
        _ request: R,
        from body: UploadBody,
        progress: TransferProgressHandler?,
        telemetry: NetworkTelemetryContext?
    ) async throws -> HTTPResponse<R.ReturnType> {
        try Task.checkCancellation()
        let acceptedStatusCodes = request.acceptedStatusCodes
        let retryPolicy = request.retryPolicy
        let configuration = state.withCriticalRegion { $0 }

        let bodySource: RequestBodySource
        let totalBytes: Int64?
        var multipartFileURL: URL? = nil
        switch body {
        case .data(let data):
            bodySource = .provided(data)
            totalBytes = Int64(data.count)
        case .file(let fileURL):
            totalBytes = try await fileIOExecutor.run {
                try Self.validateUploadSource(fileURL)
                let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                return values.fileSize.map(Int64.init)
            }
            bodySource = .provided(nil)
            multipartFileURL = nil
        case .multipart(let form):
            let fileURL = try await prepareMultipartUpload(form)
            multipartFileURL = fileURL
            totalBytes = form.estimatedByteCount
            bodySource = .provided(nil)
        }

        let urlRequest: URLRequest
        do {
            urlRequest = try Self.makeURLRequest(
                request,
                configuration: configuration,
                bodySource: bodySource
            )
        } catch {
            if let multipartFileURL {
                await discardUploadedFile(at: multipartFileURL)
            }
            throw error
        }

        let attemptState = CriticalState(0)
        let result: (Data, HTTPURLResponse)
        do {
            switch body {
            case .data(let data):
                result = try await performDataRequest(
                    urlRequest,
                    acceptedStatusCodes: acceptedStatusCodes,
                    retryPolicy: retryPolicy,
                    telemetry: telemetry
                ) {
                    let attempt = attemptState.withCriticalRegion { value in
                        value += 1
                        return value
                    }
                    progress?(TransferProgress(
                        operation: .upload,
                        phase: .started,
                        bytesCompleted: 0,
                        totalBytes: totalBytes,
                        attempt: attempt
                    ))
                    let delegate = progress.map {
                        TransferProgressDelegate(
                            operation: .upload,
                            attempt: attempt,
                            handler: $0
                        )
                    }
                    return try await self.urlSession.upload(
                        for: urlRequest,
                        from: data,
                        delegate: delegate
                    )
                }
            case .file(let fileURL):
                result = try await performDataRequest(
                    urlRequest,
                    acceptedStatusCodes: acceptedStatusCodes,
                    retryPolicy: retryPolicy,
                    beforeRetry: {
                        try await self.fileIOExecutor.run {
                            try Self.validateUploadSource(fileURL)
                        }
                    },
                    telemetry: telemetry
                ) {
                    let attempt = attemptState.withCriticalRegion { value in
                        value += 1
                        return value
                    }
                    progress?(TransferProgress(
                        operation: .upload,
                        phase: .started,
                        bytesCompleted: 0,
                        totalBytes: totalBytes,
                        attempt: attempt
                    ))
                    let delegate = progress.map {
                        TransferProgressDelegate(
                            operation: .upload,
                            attempt: attempt,
                            handler: $0
                        )
                    }
                    return try await self.urlSession.upload(
                        for: urlRequest,
                        fromFile: fileURL,
                        delegate: delegate
                    )
                }
            case .multipart(let form):
                guard let multipartFileURL else {
                    throw NetworkError.fileOperationFailed(
                        FileTransferError.sourceDoesNotExist(URL(fileURLWithPath: ""))
                    )
                }
                result = try await performDataRequest(
                    urlRequest,
                    acceptedStatusCodes: acceptedStatusCodes,
                    retryPolicy: retryPolicy,
                    beforeRetry: {
                        try await self.fileIOExecutor.run {
                            try form.validateSources()
                        }
                    },
                    telemetry: telemetry
                ) {
                    let attempt = attemptState.withCriticalRegion { value in
                        value += 1
                        return value
                    }
                    progress?(TransferProgress(
                        operation: .upload,
                        phase: .started,
                        bytesCompleted: 0,
                        totalBytes: totalBytes,
                        attempt: attempt
                    ))
                    let delegate = progress.map {
                        TransferProgressDelegate(
                            operation: .upload,
                            attempt: attempt,
                            handler: $0
                        )
                    }
                    return try await self.urlSession.upload(
                        for: urlRequest,
                        fromFile: multipartFileURL,
                        delegate: delegate
                    )
                }
            }
        } catch {
            if let multipartFileURL {
                await discardUploadedFile(at: multipartFileURL)
            }
            progress?(TransferProgress(
                operation: .upload,
                phase: Task.isCancelled || error is CancellationError
                    ? .cancelled
                    : .failed,
                bytesCompleted: totalBytes ?? 0,
                totalBytes: totalBytes,
                attempt: max(1, attemptState.withCriticalRegion { $0 })
            ))
            throw error
        }

        if let multipartFileURL {
            await discardUploadedFile(at: multipartFileURL)
        }

        progress?(TransferProgress(
            operation: .upload,
            phase: .completed,
            bytesCompleted: totalBytes ?? 0,
            totalBytes: totalBytes,
            attempt: max(1, attemptState.withCriticalRegion { $0 })
        ))

        return try Self.makeResponse(
            request,
            data: result.0,
            response: result.1,
            configuration: configuration
        )
    }

    /// Downloads a response body directly to a durable file location.
    ///
    /// Cancellation wins before the serialized final-storage phase starts.
    /// Once destination preflight begins, the storage result wins over a late
    /// cancellation so a successfully stored file URL is never hidden.
    public func download<R: DownloadRequest>(
        _ request: R,
        to destination: DownloadDestination
    ) async throws -> DownloadResponse {
        let telemetryContext = beginTelemetry(.download)
        do {
            let response: DownloadResponse
            if let activityMonitor {
                response = try await activityMonitor.trackCommitted(.download) {
                    try await self.downloadWithoutMonitoring(
                        request,
                        to: destination,
                        progress: nil,
                        telemetry: telemetryContext
                    )
                }
            } else {
                response = try await downloadWithoutMonitoring(
                    request,
                    to: destination,
                    progress: nil,
                    telemetry: telemetryContext
                )
            }
            finishTelemetry(
                telemetryContext,
                statusCode: response.statusCode,
                bytesReceived: response.value(forHTTPHeaderField: "Content-Length")
                    .flatMap(Int64.init)
            )
            return response
        } catch {
            finishTelemetry(telemetryContext, error: error)
            throw error
        }
    }

    /// Downloads directly to disk while reporting opt-in byte and lifecycle
    /// progress. Successful bodies remain file-backed and are never loaded
    /// into memory.
    public func download<R: DownloadRequest>(
        _ request: R,
        to destination: DownloadDestination,
        progress: @escaping TransferProgressHandler
    ) async throws -> DownloadResponse {
        let telemetryContext = beginTelemetry(.download)
        do {
            let response: DownloadResponse
            if let activityMonitor {
                response = try await activityMonitor.trackCommitted(.download) {
                    try await self.downloadWithoutMonitoring(
                        request,
                        to: destination,
                        progress: progress,
                        telemetry: telemetryContext
                    )
                }
            } else {
                response = try await downloadWithoutMonitoring(
                    request,
                    to: destination,
                    progress: progress,
                    telemetry: telemetryContext
                )
            }
            finishTelemetry(
                telemetryContext,
                statusCode: response.statusCode,
                bytesReceived: response.value(forHTTPHeaderField: "Content-Length")
                    .flatMap(Int64.init)
            )
            return response
        } catch {
            finishTelemetry(telemetryContext, error: error)
            throw error
        }
    }

    private func downloadWithoutMonitoring<R: DownloadRequest>(
        _ request: R,
        to destination: DownloadDestination,
        progress: TransferProgressHandler?,
        telemetry: NetworkTelemetryContext?
    ) async throws -> DownloadResponse {
        try Task.checkCancellation()
        let acceptedStatusCodes = request.acceptedStatusCodes
        let retryPolicy = request.retryPolicy
        let configuration = state.withCriticalRegion { $0 }
        try await fileIOExecutor.run {
            try Self.validateDownloadDestination(destination)
        }
        let urlRequest = try Self.makeURLRequest(
            request,
            configuration: configuration
        )

        var attempt = 1
        while true {
            try Task.checkCancellation()
            logger?.log(request: urlRequest)
            let telemetryAttemptStartedAt = DispatchTime.now().uptimeNanoseconds
            telemetry?.emit(phase: .attemptStarted, attempt: attempt)

            let progressDelegate = progress.map {
                TransferProgressDelegate(
                    operation: .download,
                    attempt: attempt,
                    handler: $0
                )
            }
            progress?(TransferProgress(
                operation: .download,
                phase: .started,
                bytesCompleted: 0,
                attempt: attempt
            ))

            let temporaryURL: URL
            let response: URLResponse
            do {
                (temporaryURL, response) = try await downloadOperationWithDelegate(
                    urlRequest,
                    progressDelegate
                )
            } catch {
                let networkError = try Self.mappedTransportError(error)
                try Task.checkCancellation()
                let retryDelay: UInt64?
                if !retryPolicy.isNever,
                   case .transport(let urlError) = networkError {
                    retryDelay = retryPolicy.retryDelayNanoseconds(
                        afterAttempt: attempt,
                        method: urlRequest.httpMethod ?? "",
                        failure: .transport(urlError),
                        now: retryNow(),
                        randomUnitValue: retryRandom()
                    )
                } else {
                    retryDelay = nil
                }
                try Task.checkCancellation()
                guard let delay = retryDelay else {
                    progress?(TransferProgress(
                        operation: .download,
                        phase: Task.isCancelled || error is CancellationError
                            ? .cancelled
                            : .failed,
                        bytesCompleted: progressDelegate?.latest.bytesCompleted ?? 0,
                        totalBytes: progressDelegate?.latest.totalBytes,
                        attempt: attempt
                    ))
                    throw networkError
                }
                logger?.logRetry(
                    nextAttempt: attempt + 1,
                    delayNanoseconds: delay
                )
                try await waitBeforeRetry(delay)
                attempt += 1
                continue
            }

            var ownsTemporaryFile = true
            let httpResponse: HTTPURLResponse
            do {
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else {
                    logger?.log(response: response, data: Data())
                    try Task.checkCancellation()
                    throw NetworkError.invalidResponse
                }
                httpResponse = response

                guard acceptedStatusCodes.accepts(httpResponse.statusCode) else {
                    try Task.checkCancellation()
                    telemetry?.emit(
                        phase: .attemptFailed,
                        attempt: attempt,
                        statusCode: httpResponse.statusCode,
                        errorKind: .httpStatus,
                        durationNanoseconds: telemetry?.attemptElapsed(
                            since: telemetryAttemptStartedAt
                        )
                    )
                    let metadataOnlyFailure = Self.makeHTTPFailure(
                        response: httpResponse,
                        data: nil
                    )
                    let retryDelay: UInt64?
                    if retryPolicy.isNever {
                        retryDelay = nil
                    } else {
                        retryDelay = retryPolicy.retryDelayNanoseconds(
                            afterAttempt: attempt,
                            method: urlRequest.httpMethod ?? "",
                            failure: .response(metadataOnlyFailure),
                            now: retryNow(),
                            randomUnitValue: retryRandom()
                        )
                    }
                    try Task.checkCancellation()
                    if let delay = retryDelay {
                        logger?.log(response: response, data: Data())
                        await discardDownloadedFile(at: temporaryURL)
                        ownsTemporaryFile = false
                        try Task.checkCancellation()
                        logger?.logRetry(
                            nextAttempt: attempt + 1,
                            delayNanoseconds: delay
                        )
                        try await waitBeforeRetry(delay)
                        attempt += 1
                        continue
                    }

                    let errorData = try await fileIOExecutor.run {
                        Self.readDownloadErrorData(at: temporaryURL)
                    }
                    logger?.log(response: response, data: errorData ?? Data())
                    try Task.checkCancellation()
                    throw NetworkError.requestFailed(Self.makeHTTPFailure(
                        response: httpResponse,
                        data: errorData
                    ))
                }

                logger?.log(response: response, data: Data())
                try Task.checkCancellation()
                telemetry?.emit(
                    phase: .attemptCompleted,
                    attempt: attempt,
                    statusCode: httpResponse.statusCode,
                    bytesReceived: httpResponse.expectedContentLength >= 0
                        ? httpResponse.expectedContentLength
                        : nil,
                    durationNanoseconds: telemetry?.attemptElapsed(
                        since: telemetryAttemptStartedAt
                    )
                )
            } catch {
                if ownsTemporaryFile {
                    await discardDownloadedFile(at: temporaryURL)
                }
                progress?(TransferProgress(
                    operation: .download,
                    phase: Task.isCancelled || error is CancellationError
                        ? .cancelled
                        : .failed,
                    bytesCompleted: progressDelegate?.latest.bytesCompleted ?? 0,
                    totalBytes: response.expectedContentLength >= 0
                        ? response.expectedContentLength
                        : progressDelegate?.latest.totalBytes,
                    attempt: attempt
                ))
                try Task.checkCancellation()
                throw error
            }

            let storedURL: URL
            do {
                storedURL = try await fileIOExecutor.runCommitted {
                    try Self.storeDownloadedFile(
                        at: temporaryURL,
                        destination: destination
                    )
                }
            } catch is CancellationError {
                await discardDownloadedFile(at: temporaryURL)
                progress?(TransferProgress(
                    operation: .download,
                    phase: .cancelled,
                    bytesCompleted: progressDelegate?.latest.bytesCompleted ?? 0,
                    totalBytes: progressDelegate?.latest.totalBytes,
                    attempt: attempt
                ))
                throw CancellationError()
            } catch let error as NetworkError {
                await discardDownloadedFile(at: temporaryURL)
                progress?(TransferProgress(
                    operation: .download,
                    phase: .failed,
                    bytesCompleted: progressDelegate?.latest.bytesCompleted ?? 0,
                    totalBytes: progressDelegate?.latest.totalBytes,
                    attempt: attempt
                ))
                throw error
            } catch {
                await discardDownloadedFile(at: temporaryURL)
                progress?(TransferProgress(
                    operation: .download,
                    phase: Task.isCancelled || error is CancellationError
                        ? .cancelled
                        : .failed,
                    bytesCompleted: progressDelegate?.latest.bytesCompleted ?? 0,
                    totalBytes: progressDelegate?.latest.totalBytes,
                    attempt: attempt
                ))
                throw NetworkError.fileOperationFailed(error)
            }

            let latestProgress = progressDelegate?.latest
            let totalBytes = httpResponse.expectedContentLength >= 0
                ? httpResponse.expectedContentLength
                : latestProgress?.totalBytes
            progress?(TransferProgress(
                operation: .download,
                phase: .completed,
                bytesCompleted: max(
                    latestProgress?.bytesCompleted ?? 0,
                    totalBytes ?? 0
                ),
                totalBytes: totalBytes,
                attempt: attempt
            ))

            return DownloadResponse(
                fileURL: storedURL,
                metadata: HTTPResponseMetadata(httpResponse)
            )
        }
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
            try Task.checkCancellation()
            do {
                urlRequest.httpBody = try request.makeBody(
                    using: configuration.encoderFactory()
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw NetworkError.encodingFailed(error)
            }
            try Task.checkCancellation()
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
        try Task.checkCancellation()

        return urlRequest
    }

    private func performDataRequest(
        _ urlRequest: URLRequest,
        acceptedStatusCodes: HTTPStatusPolicy,
        retryPolicy: HTTPRetryPolicy,
        beforeRetry: (@Sendable () async throws -> Void)? = nil,
        telemetry: NetworkTelemetryContext? = nil,
        operation: @Sendable () async throws -> (Data, URLResponse)
    ) async throws -> (Data, HTTPURLResponse) {
        if retryPolicy.isNever {
            return try await performDataAttempt(
                urlRequest,
                acceptedStatusCodes: acceptedStatusCodes,
                attempt: 1,
                telemetry: telemetry,
                operation: operation
            )
        }

        var attempt = 1
        while true {
            do {
                return try await performDataAttempt(
                    urlRequest,
                    acceptedStatusCodes: acceptedStatusCodes,
                    attempt: attempt,
                    telemetry: telemetry,
                    operation: operation
                )
            } catch let error as NetworkError {
                try Task.checkCancellation()
                let failure: HTTPRetryFailure
                switch error {
                case .transport(let urlError):
                    failure = .transport(urlError)
                case .requestFailed(let httpFailure):
                    failure = .response(httpFailure)
                default:
                    throw error
                }

                let retryDelay = retryPolicy.retryDelayNanoseconds(
                    afterAttempt: attempt,
                    method: urlRequest.httpMethod ?? "",
                    failure: failure,
                    now: retryNow(),
                    randomUnitValue: retryRandom()
                )
                try Task.checkCancellation()
                guard let delay = retryDelay else {
                    throw error
                }

                logger?.logRetry(
                    nextAttempt: attempt + 1,
                    delayNanoseconds: delay
                )
                try await waitBeforeRetry(delay)
                if let beforeRetry {
                    try await beforeRetry()
                }
                attempt += 1
            }
        }
    }

    private func performDataAttempt(
        _ urlRequest: URLRequest,
        acceptedStatusCodes: HTTPStatusPolicy,
        attempt: Int,
        telemetry: NetworkTelemetryContext?,
        operation: @Sendable () async throws -> (Data, URLResponse)
    ) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        logger?.log(request: urlRequest)
        let attemptStartedAt = DispatchTime.now().uptimeNanoseconds
        telemetry?.emit(phase: .attemptStarted, attempt: attempt)
        var statusCode: Int?
        var bytesReceived: Int64?
        do {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await operation()
            } catch {
                throw try Self.mappedTransportError(error)
            }

            try Task.checkCancellation()
            bytesReceived = Int64(data.count)
            logger?.log(response: response, data: data)
            try Task.checkCancellation()

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }
            statusCode = httpResponse.statusCode
            guard acceptedStatusCodes.accepts(httpResponse.statusCode) else {
                throw NetworkError.requestFailed(Self.makeHTTPFailure(
                    response: httpResponse,
                    data: data
                ))
            }

            telemetry?.emit(
                phase: .attemptCompleted,
                attempt: attempt,
                statusCode: httpResponse.statusCode,
                bytesReceived: bytesReceived,
                durationNanoseconds: telemetry?.attemptElapsed(
                    since: attemptStartedAt
                )
            )
            return (data, httpResponse)
        } catch {
            telemetry?.emit(
                phase: .attemptFailed,
                attempt: attempt,
                statusCode: statusCode,
                bytesReceived: bytesReceived,
                errorKind: error is CancellationError
                    ? nil
                    : networkTelemetryErrorKind(error),
                durationNanoseconds: telemetry?.attemptElapsed(
                    since: attemptStartedAt
                )
            )
            throw error
        }
    }

    private func waitBeforeRetry(_ nanoseconds: UInt64) async throws {
        try Task.checkCancellation()
        if nanoseconds > 0 {
            do {
                try await retrySleeper(nanoseconds)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                throw error
            }
        }
        try Task.checkCancellation()
    }

    private static func makeResponse<R: Request>(
        _ request: R,
        data: Data,
        response: HTTPURLResponse,
        configuration: Configuration
    ) throws -> HTTPResponse<R.ReturnType> {
        try Task.checkCancellation()
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
        try Task.checkCancellation()

        return HTTPResponse(
            value: value,
            data: data,
            metadata: HTTPResponseMetadata(response)
        )
    }

    private static func mappedTransportError(
        _ error: any Error
    ) throws -> NetworkError {
        if Task.isCancelled || error is CancellationError {
            throw CancellationError()
        }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled, Task.isCancelled {
                throw CancellationError()
            }
            return NetworkError.transport(urlError)
        }
        return NetworkError.unknown(error)
    }

    private static func makeHTTPFailure(
        response: HTTPURLResponse,
        data: Data?
    ) -> HTTPFailure {
        HTTPFailure(
            metadata: HTTPResponseMetadata(response),
            data: data
        )
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

    /// Avoids loading an unexpectedly large failed streaming response into
    /// memory. The stream is cancelled by the caller after this method
    /// returns, so this method intentionally stops as soon as the limit is
    /// exceeded.
    private static func readStreamErrorData(
        _ bytes: URLSession.AsyncBytes
    ) async -> Data? {
        let maximumBytes = 1_048_576
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 4_096))

        do {
            for try await byte in bytes {
                guard data.count < maximumBytes else { return nil }
                data.append(byte)
            }
            return data
        } catch {
            return data.isEmpty ? nil : data
        }
    }

    private func discardDownloadedFile(at url: URL) async {
        await fileIOExecutor.runCleanup {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func discardUploadedFile(at url: URL) async {
        await fileIOExecutor.runCleanup {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func prepareMultipartUpload(
        _ form: StreamingMultipartFormData
    ) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnotherFuckingNetworkingSDK-Multipart",
                isDirectory: true
            )
        let url = directory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: false
        )
        do {
            try await fileIOExecutor.runCommitted {
                try form.write(to: url)
            }
            return url
        } catch {
            await discardUploadedFile(at: url)
            throw error
        }
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
    var acceptedStatusCodes: HTTPStatusPolicy { wrapped.acceptedStatusCodes }
    var retryPolicy: HTTPRetryPolicy { wrapped.retryPolicy }
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
