import Foundation

/// The lifecycle phase represented by a telemetry event.
public enum NetworkTelemetryPhase: String, Equatable, Sendable {
    case started
    case attemptStarted
    case attemptCompleted
    case attemptFailed
    case succeeded
    case failed
    case cancelled
}

/// A privacy-safe category for a failed networking operation.
public enum NetworkTelemetryErrorKind: String, Equatable, Sendable {
    case transport
    case httpStatus
    case decoding
    case invalidResponse
    case configuration
    case fileOperation
    case websocket
    case unknown
}

/// A Sendable subset of URLSession task metrics suitable for exporters.
public struct NetworkTaskMetricsSnapshot: Equatable, Sendable {
    public let fetchStart: Date?
    public let responseStart: Date?
    public let responseEnd: Date?
    public let domainLookupDurationNanoseconds: UInt64?
    public let secureConnectionDurationNanoseconds: UInt64?
    public let requestDurationNanoseconds: UInt64?

    public init(
        fetchStart: Date? = nil,
        responseStart: Date? = nil,
        responseEnd: Date? = nil,
        domainLookupDurationNanoseconds: UInt64? = nil,
        secureConnectionDurationNanoseconds: UInt64? = nil,
        requestDurationNanoseconds: UInt64? = nil
    ) {
        self.fetchStart = fetchStart
        self.responseStart = responseStart
        self.responseEnd = responseEnd
        self.domainLookupDurationNanoseconds = domainLookupDurationNanoseconds
        self.secureConnectionDurationNanoseconds = secureConnectionDurationNanoseconds
        self.requestDurationNanoseconds = requestDurationNanoseconds
    }
}

/// One privacy-safe operation or attempt observation.
public struct NetworkTelemetryEvent: Equatable, Sendable {
    public let operationID: UInt64
    public let kind: NetworkOperationKind
    public let phase: NetworkTelemetryPhase
    public let attempt: Int
    public let durationNanoseconds: UInt64?
    public let statusCode: Int?
    public let bytesSent: Int64?
    public let bytesReceived: Int64?
    public let errorKind: NetworkTelemetryErrorKind?
    public let taskMetrics: NetworkTaskMetricsSnapshot?

    public init(
        operationID: UInt64,
        kind: NetworkOperationKind,
        phase: NetworkTelemetryPhase,
        attempt: Int = 1,
        durationNanoseconds: UInt64? = nil,
        statusCode: Int? = nil,
        bytesSent: Int64? = nil,
        bytesReceived: Int64? = nil,
        errorKind: NetworkTelemetryErrorKind? = nil,
        taskMetrics: NetworkTaskMetricsSnapshot? = nil
    ) {
        self.operationID = operationID
        self.kind = kind
        self.phase = phase
        self.attempt = max(1, attempt)
        self.durationNanoseconds = durationNanoseconds
        self.statusCode = statusCode
        self.bytesSent = bytesSent.flatMap { $0 >= 0 ? $0 : nil }
        self.bytesReceived = bytesReceived.flatMap { $0 >= 0 ? $0 : nil }
        self.errorKind = errorKind
        self.taskMetrics = taskMetrics
    }
}

/// A minimal exporter bridge for metrics systems such as OpenTelemetry.
///
/// The SDK emits stable values rather than depending on a metrics vendor. An
/// application can adapt this protocol to spans, counters, signposts, or a
/// privacy-reviewed telemetry backend.
public protocol NetworkTelemetryExporter: Sendable {
    func export(_ event: NetworkTelemetryEvent)
}

/// Opt-in telemetry delivery. No events or clocks are allocated when a client
/// is created without a telemetry sink.
public struct NetworkTelemetry: Sendable {
    public typealias Sink = @Sendable (NetworkTelemetryEvent) -> Void

    private let sink: Sink

    public init(sink: @escaping Sink) {
        self.sink = sink
    }

    public init(exporter: any NetworkTelemetryExporter) {
        sink = { event in exporter.export(event) }
    }

    public func record(_ event: NetworkTelemetryEvent) {
        sink(event)
    }
}

struct NetworkTelemetryContext: Sendable {
    let telemetry: NetworkTelemetry
    let operationID: UInt64
    let kind: NetworkOperationKind
    let startedAt: UInt64

    init(
        telemetry: NetworkTelemetry,
        operationID: UInt64,
        kind: NetworkOperationKind
    ) {
        self.telemetry = telemetry
        self.operationID = operationID
        self.kind = kind
        startedAt = DispatchTime.now().uptimeNanoseconds
    }

    func emit(
        phase: NetworkTelemetryPhase,
        attempt: Int = 1,
        statusCode: Int? = nil,
        bytesSent: Int64? = nil,
        bytesReceived: Int64? = nil,
        errorKind: NetworkTelemetryErrorKind? = nil,
        durationNanoseconds: UInt64? = nil,
        taskMetrics: NetworkTaskMetricsSnapshot? = nil
    ) {
        telemetry.record(NetworkTelemetryEvent(
            operationID: operationID,
            kind: kind,
            phase: phase,
            attempt: attempt,
            durationNanoseconds: durationNanoseconds,
            statusCode: statusCode,
            bytesSent: bytesSent,
            bytesReceived: bytesReceived,
            errorKind: errorKind,
            taskMetrics: taskMetrics
        ))
    }

    func elapsedNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds &- startedAt
    }

    func attemptElapsed(since start: UInt64) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds &- start
    }

    func beginLease() -> @Sendable (NetworkActivityOutcome) -> Void {
        let completed = CriticalState(false)
        return { [telemetry, operationID, kind, startedAt] outcome in
            let shouldEmit = completed.withCriticalRegion { value in
                guard !value else { return false }
                value = true
                return true
            }
            guard shouldEmit else { return }
            let phase: NetworkTelemetryPhase
            switch outcome {
            case .succeeded:
                phase = .succeeded
            case .failed:
                phase = .failed
            case .cancelled:
                phase = .cancelled
            }
            telemetry.record(NetworkTelemetryEvent(
                operationID: operationID,
                kind: kind,
                phase: phase,
                durationNanoseconds: DispatchTime.now().uptimeNanoseconds
                    &- startedAt,
                errorKind: phase == .failed ? .unknown : nil
            ))
        }
    }
}

func networkTelemetryErrorKind(_ error: any Error) -> NetworkTelemetryErrorKind {
    if let networkError = error as? NetworkError {
        switch networkError {
        case .transport:
            return .transport
        case .requestFailed:
            return .httpStatus
        case .decodingFailed, .emptyResponse:
            return .decoding
        case .invalidResponse:
            return .invalidResponse
        case .encodingFailed, .requestConfigurationFailed, .invalidURL:
            return .configuration
        case .fileOperationFailed:
            return .fileOperation
        case .unknown:
            return .unknown
        }
    }
    if error is URLError { return .transport }
    if error is DecodingError { return .decoding }
    if error is WebSocketError { return .websocket }
    return .unknown
}
