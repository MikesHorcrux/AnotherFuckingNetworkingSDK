import Foundation
import OSLog

/// An opt-in, redacting logger for networking diagnostics.
///
/// Raw requests and response bodies are sanitized before they reach the sink.
/// The default sink writes the sanitized message to unified logging.
public struct NetworkingLogger: Sendable {
    public enum Level: Equatable, Sendable {
        case debug
        case info
        case error
    }

    /// Controls whether a request or response body may appear in a log message.
    public enum BodyPolicy: Equatable, Sendable {
        /// Never include body contents.
        case omitted

        /// Include valid JSON no larger than the limit after recursively
        /// redacting configured keys. Invalid, binary, and oversized bodies
        /// are represented only by their byte count.
        case redactedJSON(maximumBytes: Int)
    }

    /// Controls whether URL paths may appear in diagnostics.
    public enum URLPathPolicy: Equatable, Sendable {
        /// Replace every non-root path with the redaction placeholder.
        case redacted

        /// Include the path. Use only when paths cannot contain sensitive values.
        case included
    }

    /// Immutable logging and redaction settings.
    public struct Configuration: Sendable {
        public static let defaultRedactedHeaders: Set<String> = [
            "authorization",
            "proxy-authorization",
            "cookie",
            "set-cookie",
            "x-api-key",
            "api-key"
        ]

        public static let defaultRedactedQueryItems: Set<String> = [
            "access_token",
            "refresh_token",
            "api_key",
            "client_secret",
            "id_token",
            "token",
            "password",
            "secret",
            "code"
        ]

        public static let defaultRedactedJSONKeys: Set<String> = [
            "access_token",
            "refresh_token",
            "api_key",
            "client_secret",
            "id_token",
            "token",
            "authorization",
            "password",
            "secret",
            "code"
        ]

        public let redactedHeaders: Set<String>
        public let redactedQueryItems: Set<String>
        public let redactedJSONKeys: Set<String>
        public let bodyPolicy: BodyPolicy
        public let redactionPlaceholder: String
        public let redactsURLFragment: Bool
        public let urlPathPolicy: URLPathPolicy

        public init(
            redactedHeaders: Set<String> = Self.defaultRedactedHeaders,
            redactedQueryItems: Set<String> = Self.defaultRedactedQueryItems,
            redactedJSONKeys: Set<String> = Self.defaultRedactedJSONKeys,
            bodyPolicy: BodyPolicy = .omitted,
            redactionPlaceholder: String = "<redacted>",
            redactsURLFragment: Bool = true,
            urlPathPolicy: URLPathPolicy = .redacted
        ) {
            self.redactedHeaders = Self.normalized(redactedHeaders)
            self.redactedQueryItems = Self.normalized(redactedQueryItems)
            self.redactedJSONKeys = Self.normalized(redactedJSONKeys)
            self.bodyPolicy = bodyPolicy
            self.redactionPlaceholder = redactionPlaceholder
            self.redactsURLFragment = redactsURLFragment
            self.urlPathPolicy = urlPathPolicy
        }

        fileprivate static func normalizedKey(_ value: String) -> String {
            value.lowercased().filter { $0.isLetter || $0.isNumber }
        }

        private static func normalized(_ values: Set<String>) -> Set<String> {
            Set(values.map(normalizedKey(_:)))
        }
    }

    public typealias Sink = @Sendable (Level, String) -> Void

    public let configuration: Configuration

    private let sink: Sink

    public init(configuration: Configuration = Configuration()) {
        self.init(configuration: configuration, sink: Self.defaultSink)
    }

    public init(
        configuration: Configuration = Configuration(),
        sink: @escaping Sink
    ) {
        self.configuration = configuration
        self.sink = sink
    }

    /// Emits a sanitized cURL representation of a request.
    public func log(request: URLRequest) {
        sink(.debug, "Outgoing request:\n\(curlCommand(for: request))")
    }

    /// Emits a sanitized HTTP response summary.
    public func log(response: URLResponse, data: Data) {
        guard let response = response as? HTTPURLResponse else {
            sink(.error, "Received a non-HTTP response.")
            return
        }

        let url = response.url.map { sanitizedURL($0).absoluteString }
            ?? "<unknown URL>"
        let body = sanitizedBody(data).description
        sink(.info, "Response \(response.statusCode) from \(url):\n\(body)")
    }

    /// Returns a shell-safe cURL command containing only sanitized values.
    public func curlCommand(for request: URLRequest) -> String {
        var arguments = ["curl"]
        arguments.append(contentsOf: [
            "--request",
            shellQuote(request.httpMethod ?? HTTPMethod.get.rawValue),
            "--url",
            shellQuote(sanitizedURL(request.url).absoluteString)
        ])

        let headers = (request.allHTTPHeaderFields ?? [:]).sorted {
            let comparison = $0.key.caseInsensitiveCompare($1.key)
            return comparison == .orderedSame
                ? $0.key < $1.key
                : comparison == .orderedAscending
        }
        for (name, value) in headers {
            let sanitizedValue = configuration.redactedHeaders.contains(
                Configuration.normalizedKey(name)
            )
                ? configuration.redactionPlaceholder
                : value
            arguments.append("--header")
            arguments.append(shellQuote("\(name): \(sanitizedValue)"))
        }

        if let body = request.httpBody, !body.isEmpty {
            switch sanitizedBody(body) {
            case .included(let value):
                arguments.append("--data-binary")
                arguments.append(shellQuote(value))
            case .omitted(let description):
                arguments.append("# \(description)")
            }
        } else if request.httpBodyStream != nil {
            arguments.append("# streaming body omitted")
        }

        return arguments.joined(separator: " ")
    }

    private func sanitizedURL(_ url: URL?) -> URL {
        guard let url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return URL(string: "about:blank")!
        }

        if components.user != nil {
            components.user = configuration.redactionPlaceholder
        }
        if components.password != nil {
            components.password = configuration.redactionPlaceholder
        }
        if configuration.urlPathPolicy == .redacted,
           !components.path.isEmpty,
           components.path != "/" {
            components.path = "/\(configuration.redactionPlaceholder)"
        }
        components.queryItems = components.queryItems?.map { item in
            guard configuration.redactedQueryItems.contains(
                Configuration.normalizedKey(item.name)
            ) else {
                return item
            }
            return URLQueryItem(
                name: item.name,
                value: item.value == nil ? nil : configuration.redactionPlaceholder
            )
        }
        if configuration.redactsURLFragment, components.fragment != nil {
            components.fragment = configuration.redactionPlaceholder
        }

        return components.url ?? URL(string: "about:blank")!
    }

    private func sanitizedBody(_ data: Data) -> SanitizedBody {
        switch configuration.bodyPolicy {
        case .omitted:
            return .omitted("body omitted: \(data.count) bytes")

        case .redactedJSON(let maximumBytes):
            guard maximumBytes >= 0, data.count <= maximumBytes else {
                return .omitted("body omitted: \(data.count) bytes")
            }

            do {
                let object = try JSONSerialization.jsonObject(
                    with: data,
                    options: [.fragmentsAllowed]
                )
                let sanitized = sanitizeJSON(object)
                let sanitizedData = try JSONSerialization.data(
                    withJSONObject: sanitized,
                    options: [.sortedKeys, .fragmentsAllowed]
                )
                guard let body = String(data: sanitizedData, encoding: .utf8) else {
                    return .omitted("body omitted: \(data.count) bytes")
                }
                return .included(body)
            } catch {
                return .omitted("body omitted: \(data.count) bytes")
            }
        }
    }

    private func sanitizeJSON(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, pair in
                let (key, value) = pair
                result[key] = configuration.redactedJSONKeys.contains(
                    Configuration.normalizedKey(key)
                )
                    ? configuration.redactionPlaceholder
                    : sanitizeJSON(value)
            }
        }

        if let array = value as? [Any] {
            return array.map(sanitizeJSON(_:))
        }

        return value
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private enum SanitizedBody {
        case included(String)
        case omitted(String)

        var description: String {
            switch self {
            case .included(let value):
                return value
            case .omitted(let value):
                return "<\(value)>"
            }
        }
    }

    private static let osLogger = Logger(
        subsystem: "com.mikeshorcrux.AnotherFuckingNetworkingSDK",
        category: "Networking"
    )

    private static let defaultSink: Sink = { level, message in
        switch level {
        case .debug:
            osLogger.debug("\(message, privacy: .public)")
        case .info:
            osLogger.info("\(message, privacy: .public)")
        case .error:
            osLogger.error("\(message, privacy: .public)")
        }
    }
}
