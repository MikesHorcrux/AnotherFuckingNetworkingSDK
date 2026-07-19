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

/// Defines which HTTP response status codes a request accepts as successful.
///
/// Status acceptance is independent of response-body decoding. For example,
/// accepting `204` or `304` does not by itself allow an empty response body.
public struct HTTPStatusPolicy: Equatable, Sendable {
    /// Accepts the standard successful range, `200...299`.
    public static let successful = Self(storage: .successful)

    /// Accepts every status code.
    public static let all = Self(storage: .all)

    /// Rejects every status code.
    public static let none = Self(storage: .ranges([]))

    private enum Storage: Equatable, Sendable {
        case successful
        case all
        case ranges([ClosedRange<Int>])
    }

    private let storage: Storage

    /// Creates a policy from inclusive status-code ranges.
    ///
    /// Overlapping and adjacent ranges are normalized once during creation.
    /// Supplying no ranges creates ``none``.
    public init(_ acceptedRanges: ClosedRange<Int>...) {
        self.init(ranges: acceptedRanges)
    }

    /// Creates a policy from a collection of inclusive status-code ranges.
    public init(ranges acceptedRanges: [ClosedRange<Int>]) {
        storage = Self.normalizedStorage(for: acceptedRanges)
    }

    /// Creates a policy that accepts only the supplied exact status codes.
    public static func codes(_ acceptedStatusCodes: Set<Int>) -> Self {
        Self(ranges: acceptedStatusCodes.map { $0...$0 })
    }

    /// Returns whether this policy accepts `statusCode`.
    public func accepts(_ statusCode: Int) -> Bool {
        switch storage {
        case .successful:
            return (200...299).contains(statusCode)
        case .all:
            return true
        case .ranges(let ranges):
            var lowerBound = 0
            var upperBound = ranges.count

            while lowerBound < upperBound {
                let index = lowerBound + (upperBound - lowerBound) / 2
                let range = ranges[index]
                if statusCode < range.lowerBound {
                    upperBound = index
                } else if statusCode > range.upperBound {
                    lowerBound = index + 1
                } else {
                    return true
                }
            }
            return false
        }
    }

    private init(storage: Storage) {
        self.storage = storage
    }

    private static func normalizedStorage(
        for acceptedRanges: [ClosedRange<Int>]
    ) -> Storage {
        guard !acceptedRanges.isEmpty else { return .ranges([]) }

        let sortedRanges = acceptedRanges.sorted {
            if $0.lowerBound == $1.lowerBound {
                return $0.upperBound < $1.upperBound
            }
            return $0.lowerBound < $1.lowerBound
        }
        var normalized: [ClosedRange<Int>] = []
        normalized.reserveCapacity(sortedRanges.count)

        for range in sortedRanges {
            guard let previous = normalized.last else {
                normalized.append(range)
                continue
            }

            let overlaps = range.lowerBound <= previous.upperBound
            let isAdjacent = previous.upperBound < Int.max
                && range.lowerBound == previous.upperBound + 1
            if overlaps || isAdjacent {
                let mergedUpperBound = max(
                    previous.upperBound,
                    range.upperBound
                )
                normalized[normalized.count - 1] =
                    previous.lowerBound...mergedUpperBound
            } else {
                normalized.append(range)
            }
        }

        if normalized == [Int.min...Int.max] {
            return .all
        }
        if normalized == [200...299] {
            return .successful
        }
        return .ranges(normalized)
    }
}

// MARK: - HTTPRetryPolicy

/// Defines whether and when a failed HTTP attempt may be replayed.
///
/// Policies are immutable values. ``never`` is the default for every request,
/// so retries are always an explicit endpoint decision.
public struct HTTPRetryPolicy: Equatable, Sendable {
    /// Controls which final HTTP methods a policy may replay.
    public enum ReplaySafety: Equatable, Sendable {
        /// Replays only `GET`, `HEAD`, `PUT`, `DELETE`, and `OPTIONS`.
        case idempotentMethodsOnly

        /// The request author asserts that every attempt is safe to replay.
        ///
        /// Use this for non-idempotent methods only when the endpoint supplies
        /// an idempotency mechanism or otherwise guarantees replay safety.
        case explicitlyReplayable
    }

    /// Randomization applied to exponential backoff delays.
    public enum Jitter: Equatable, Sendable {
        /// Uses the computed exponential delay exactly.
        case none

        /// Chooses a random delay from zero through the computed delay.
        case full
    }

    /// Never retries a failed attempt.
    public static let never = Self(storage: .never)

    /// The transient response statuses used by ``transient(maximumAttempts:initialDelay:maximumDelay:multiplier:jitter:honorsRetryAfter:retryableStatusCodes:retryableURLErrorCodes:replaySafety:)``.
    public static let defaultRetryableStatusCodes = HTTPStatusPolicy.codes([
        408,
        429,
        500,
        502,
        503,
        504
    ])

    /// The transient URL failures used by ``transient(maximumAttempts:initialDelay:maximumDelay:multiplier:jitter:honorsRetryAfter:retryableStatusCodes:retryableURLErrorCodes:replaySafety:)``.
    public static let defaultRetryableURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .networkConnectionLost,
        .notConnectedToInternet
    ]

    private static let maximumAttemptLimit = 100

    private struct TransientConfiguration: Equatable, Sendable {
        let maximumAttempts: Int
        let initialDelayNanoseconds: UInt64
        let maximumDelayNanoseconds: UInt64
        let multiplier: Double
        let jitter: Jitter
        let honorsRetryAfter: Bool
        let retryableStatusCodes: HTTPStatusPolicy
        let retryableURLErrorCodes: Set<URLError.Code>
        let replaySafety: ReplaySafety
    }

    private enum Storage: Equatable, Sendable {
        case never
        case transient(TransientConfiguration)
    }

    private let storage: Storage

    /// Creates a bounded policy for common transient HTTP and URL failures.
    ///
    /// `maximumAttempts` includes the initial attempt. Values less than two
    /// create ``never`` and values above `100` are capped to prevent accidental
    /// zero-delay retry loops. Negative or `NaN` delays become zero, positive
    /// infinity saturates, the initial delay is capped to the maximum delay,
    /// and a non-finite or sub-one multiplier becomes `1`.
    ///
    /// A valid `Retry-After` delta or HTTP date takes precedence over
    /// exponential backoff. If the server asks for longer than `maximumDelay`,
    /// the failure is returned immediately instead of retrying too early.
    public static func transient(
        maximumAttempts: Int = 3,
        initialDelay: TimeInterval = 0.25,
        maximumDelay: TimeInterval = 10,
        multiplier: Double = 2,
        jitter: Jitter = .full,
        honorsRetryAfter: Bool = true,
        retryableStatusCodes: HTTPStatusPolicy =
            HTTPRetryPolicy.defaultRetryableStatusCodes,
        retryableURLErrorCodes: Set<URLError.Code> =
            HTTPRetryPolicy.defaultRetryableURLErrorCodes,
        replaySafety: ReplaySafety = .idempotentMethodsOnly
    ) -> Self {
        guard maximumAttempts > 1,
              retryableStatusCodes != .none
                || !retryableURLErrorCodes.isEmpty else {
            return .never
        }

        let maximumDelayNanoseconds = nanoseconds(for: maximumDelay)
        let initialDelayNanoseconds = min(
            nanoseconds(for: initialDelay),
            maximumDelayNanoseconds
        )
        let normalizedMultiplier = multiplier.isFinite && multiplier >= 1
            ? multiplier
            : 1

        return Self(storage: .transient(TransientConfiguration(
            maximumAttempts: min(maximumAttempts, maximumAttemptLimit),
            initialDelayNanoseconds: initialDelayNanoseconds,
            maximumDelayNanoseconds: maximumDelayNanoseconds,
            multiplier: normalizedMultiplier,
            jitter: jitter,
            honorsRetryAfter: honorsRetryAfter,
            retryableStatusCodes: retryableStatusCodes,
            retryableURLErrorCodes: retryableURLErrorCodes,
            replaySafety: replaySafety
        )))
    }

    private init(storage: Storage) {
        self.storage = storage
    }

    var isNever: Bool {
        if case .never = storage { return true }
        return false
    }

    func retryDelayNanoseconds(
        afterAttempt attempt: Int,
        method: String,
        failure: HTTPRetryFailure,
        now: Date,
        randomUnitValue: Double
    ) -> UInt64? {
        guard case .transient(let configuration) = storage,
              attempt > 0,
              attempt < configuration.maximumAttempts,
              Self.canReplay(
                method: method,
                safety: configuration.replaySafety
              ) else {
            return nil
        }

        switch failure {
        case .transport(let error):
            guard configuration.retryableURLErrorCodes.contains(error.code) else {
                return nil
            }

        case .response(let failure):
            guard configuration.retryableStatusCodes.accepts(
                failure.statusCode
            ) else {
                return nil
            }
            if configuration.honorsRetryAfter,
               let value = failure.value(forHTTPHeaderField: "Retry-After") {
                let referenceDate = failure.value(forHTTPHeaderField: "Date")
                    .flatMap {
                        Self.retryAfterDate(from: $0, referenceDate: now)
                    } ?? now
                if let delay = Self.retryAfterDelayNanoseconds(
                    value,
                    referenceDate: referenceDate,
                    maximum: configuration.maximumDelayNanoseconds
                ) {
                    return delay
                }
                if Self.isValidRetryAfter(
                    value,
                    referenceDate: referenceDate
                ) {
                    // A syntactically valid value above the configured maximum
                    // is an instruction not to retry earlier than the server
                    // asked.
                    return nil
                }
            }
        }

        let delay = Self.exponentialDelayNanoseconds(
            afterAttempt: attempt,
            configuration: configuration
        )
        guard configuration.jitter == .full else { return delay }

        let sample = randomUnitValue.isFinite
            ? min(max(randomUnitValue, 0), 1)
            : 0
        return Self.clampedNanoseconds(
            from: Double(delay) * sample,
            maximum: delay
        )
    }

    private static func canReplay(
        method: String,
        safety: ReplaySafety
    ) -> Bool {
        guard safety == .idempotentMethodsOnly else { return true }
        switch method {
        case "GET", "HEAD", "PUT", "DELETE", "OPTIONS":
            return true
        default:
            return false
        }
    }

    private static func exponentialDelayNanoseconds(
        afterAttempt attempt: Int,
        configuration: TransientConfiguration
    ) -> UInt64 {
        guard configuration.initialDelayNanoseconds > 0,
              configuration.maximumDelayNanoseconds > 0 else {
            return 0
        }

        let exponent = Double(max(0, attempt - 1))
        let scaled = Double(configuration.initialDelayNanoseconds)
            * pow(configuration.multiplier, exponent)
        guard scaled.isFinite else {
            return configuration.maximumDelayNanoseconds
        }
        return clampedNanoseconds(
            from: scaled,
            maximum: configuration.maximumDelayNanoseconds
        )
    }

    private static func retryAfterDelayNanoseconds(
        _ value: String,
        referenceDate: Date,
        maximum: UInt64
    ) -> UInt64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let delay: UInt64

        if isASCIIDecimal(trimmed) {
            guard let seconds = UInt64(trimmed),
                  seconds <= maximum / 1_000_000_000 else {
                return nil
            }
            delay = seconds * 1_000_000_000
        } else if let date = retryAfterDate(
            from: trimmed,
            referenceDate: referenceDate
        ) {
            let interval = max(0, date.timeIntervalSince(referenceDate))
            delay = nanoseconds(for: interval)
        } else {
            return nil
        }

        guard delay <= maximum else { return nil }
        return delay
    }

    private static func isValidRetryAfter(
        _ value: String,
        referenceDate: Date
    ) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if isASCIIDecimal(trimmed) { return true }
        return retryAfterDate(
            from: trimmed,
            referenceDate: referenceDate
        ) != nil
    }

    private static func isASCIIDecimal(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { byte in
            byte >= 48 && byte <= 57
        }
    }

    private static func retryAfterDate(
        from value: String,
        referenceDate: Date
    ) -> Date? {
        let formats = [
            ("EEE',' dd MMM yyyy HH':'mm':'ss zzz", false),
            ("EEEE',' dd-MMM-yy HH':'mm':'ss zzz", true),
            ("EEE MMM d HH':'mm':'ss yyyy", false)
        ]

        for (format, usesTwoDigitYear) in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: value) {
                guard usesTwoDigitYear else { return date }
                return adjustedRFC850Date(
                    date,
                    value: value,
                    referenceDate: referenceDate
                )
            }
        }
        return nil
    }

    private static func adjustedRFC850Date(
        _ parsedDate: Date,
        value: String,
        referenceDate: Date
    ) -> Date? {
        guard let comma = value.firstIndex(of: ",") else { return nil }
        let fields = value[value.index(after: comma)...]
            .split(whereSeparator: { $0.isWhitespace })
        guard let dateField = fields.first,
              let yearField = dateField.split(separator: "-").last,
              yearField.count == 2,
              let shortYear = Int(yearField) else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let referenceYear = calendar.dateComponents(
            [.year],
            from: referenceDate
        ).year else {
            return nil
        }

        var components = calendar.dateComponents(
            [.month, .day, .hour, .minute, .second],
            from: parsedDate
        )
        components.year = (referenceYear / 100) * 100 + shortYear
        guard var candidate = calendar.date(from: components),
              let fiftyYearsFromReference = calendar.date(
                byAdding: .year,
                value: 50,
                to: referenceDate
              ) else {
            return nil
        }
        if candidate > fiftyYearsFromReference {
            guard let adjusted = calendar.date(
                byAdding: .year,
                value: -100,
                to: candidate
            ) else {
                return nil
            }
            candidate = adjusted
        }
        return candidate
    }

    private static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        if interval == .infinity { return UInt64.max }
        guard interval.isFinite, interval > 0 else { return 0 }
        let scaled = interval * 1_000_000_000
        guard scaled < Double(UInt64.max) else { return UInt64.max }
        return UInt64(scaled.rounded(.towardZero))
    }

    private static func clampedNanoseconds(
        from value: Double,
        maximum: UInt64
    ) -> UInt64 {
        guard value.isFinite, value > 0 else { return 0 }
        guard value < Double(maximum) else { return maximum }
        return UInt64(value.rounded(.towardZero))
    }

}

enum HTTPRetryFailure: Sendable {
    case transport(URLError)
    case response(HTTPFailure)
}

// MARK: - NetworkError

/// An error produced while constructing, sending, or decoding a network request.
public enum NetworkError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case encodingFailed(any Error)
    case requestConfigurationFailed(any Error)
    case transport(URLError)
    case requestFailed(HTTPFailure)
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
        case .requestFailed(let failure):
            return "The server returned HTTP \(failure.statusCode)."
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

    /// The response status codes accepted by this request. The default is
    /// ``HTTPStatusPolicy/successful``.
    var acceptedStatusCodes: HTTPStatusPolicy { get }

    /// The failed-attempt replay policy. The default is ``HTTPRetryPolicy/never``.
    var retryPolicy: HTTPRetryPolicy { get }

    /// Controls whether an expired-credential request may be replayed after
    /// a 401 response. The default permits only idempotent HTTP methods.
    var authenticationReplaySafety: HTTPRetryPolicy.ReplaySafety { get }

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
    var acceptedStatusCodes: HTTPStatusPolicy { .successful }
    var retryPolicy: HTTPRetryPolicy { .never }
    var authenticationReplaySafety: HTTPRetryPolicy.ReplaySafety {
        .idempotentMethodsOnly
    }

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
        let scalars = path.unicodeScalars
        var index = scalars.startIndex

        while index != scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "%" {
                let first = scalars.index(after: index)
                guard first != scalars.endIndex else { return false }
                let second = scalars.index(after: first)
                guard second != scalars.endIndex,
                      scalars[first].isASCIIHexDigit,
                      scalars[second].isASCIIHexDigit else {
                    return false
                }
                index = scalars.index(after: second)
            } else {
                guard CharacterSet.urlPathAllowed.contains(scalar) else {
                    return false
                }
                index = scalars.index(after: index)
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

/// The response details retained when an HTTP status is rejected.
///
/// ``data`` is the response body when it was available within the operation's
/// safety limits. In particular, failed downloads omit bodies larger than the
/// documented limit rather than loading them into memory.
public struct HTTPFailure: Equatable, Sendable {
    public let metadata: HTTPResponseMetadata
    public let data: Data?

    public init(
        metadata: HTTPResponseMetadata,
        data: Data? = nil
    ) {
        self.metadata = metadata
        self.data = data
    }

    public var statusCode: Int { metadata.statusCode }
    public var url: URL? { metadata.url }
    public var headers: [String: String] { metadata.headers }

    public func value(forHTTPHeaderField name: String) -> String? {
        metadata.value(forHTTPHeaderField: name)
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
