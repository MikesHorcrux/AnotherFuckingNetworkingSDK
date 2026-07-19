import Foundation

/// One parsed Server-Sent Event from an HTTP event stream.
public struct ServerSentEvent: Equatable, Sendable {
    /// The event type, or `message` when the wire omitted `event:`.
    public let event: String
    /// The optional reconnect cursor supplied by the server.
    public let id: String?
    /// The event payload with consecutive `data:` lines joined by `\n`.
    public let data: String
    /// The server's optional reconnect delay in milliseconds.
    public let retryMilliseconds: UInt64?

    public init(
        event: String = "message",
        id: String? = nil,
        data: String,
        retryMilliseconds: UInt64? = nil
    ) {
        self.event = event.isEmpty ? "message" : event
        self.id = id
        self.data = data
        self.retryMilliseconds = retryMilliseconds
    }
}

/// Errors raised while incrementally parsing a Server-Sent Events stream.
public enum ServerSentEventError: LocalizedError, Equatable, Sendable {
    case eventTooLarge(maximumBytes: Int, actualBytes: Int)
    case invalidUTF8
    case invalidRetryField

    public var errorDescription: String? {
        switch self {
        case .eventTooLarge(let maximumBytes, let actualBytes):
            return "The Server-Sent Event exceeded the \(maximumBytes)-byte limit (received \(actualBytes) bytes)."
        case .invalidUTF8:
            return "The Server-Sent Event contained an invalid UTF-8 field."
        case .invalidRetryField:
            return "The Server-Sent Event retry field was not a non-negative integer."
        }
    }
}

/// Incremental, bounded parser for the Server-Sent Events wire format.
public struct ServerSentEventParser: Sendable {
    public static let defaultMaximumEventBytes = 256 * 1_024

    private let maximumEventBytes: Int
    private var line: [UInt8] = []
    private var eventBytes = 0
    private var eventName: String?
    private var eventID: String?
    private var dataLines: [String] = []
    private var retryMilliseconds: UInt64?
    private var pendingCarriageReturn = false

    public init(
        maximumEventBytes: Int = Self.defaultMaximumEventBytes
    ) {
        self.maximumEventBytes = Swift.max(1, maximumEventBytes)
    }

    /// Appends bytes and returns every complete event made available by them.
    public mutating func append(_ data: Data) throws -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        events.reserveCapacity(1)
        for byte in data {
            events.append(contentsOf: try append(byte))
        }
        return events
    }

    /// Finishes the stream, parsing a final unterminated line if present.
    public mutating func finish() throws -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        if !line.isEmpty {
            events.append(contentsOf: try processLine())
            line.removeAll(keepingCapacity: true)
        }
        events.append(contentsOf: dispatch())
        return events
    }

    fileprivate mutating func append(_ byte: UInt8) throws -> [ServerSentEvent] {
        if pendingCarriageReturn {
            pendingCarriageReturn = false
            if byte == 0x0A {
                return []
            }
        }

        if byte == 0x0A || byte == 0x0D {
            if byte == 0x0D {
                pendingCarriageReturn = true
            }
            let events = try processLine()
            line.removeAll(keepingCapacity: true)
            return events
        }

        line.append(byte)
        guard line.count + eventBytes <= maximumEventBytes else {
            throw ServerSentEventError.eventTooLarge(
                maximumBytes: maximumEventBytes,
                actualBytes: line.count + eventBytes
            )
        }
        return []
    }

    private mutating func processLine() throws -> [ServerSentEvent] {
        eventBytes += line.count
        guard eventBytes <= maximumEventBytes else {
            throw ServerSentEventError.eventTooLarge(
                maximumBytes: maximumEventBytes,
                actualBytes: eventBytes
            )
        }
        guard !line.isEmpty else {
            return dispatch()
        }

        let separator = line.firstIndex(of: 0x3A)
        let fieldBytes = separator.map { line[..<$0] } ?? line[...]
        let valueStart = separator.map { line.index(after: $0) }
        var valueBytes = valueStart.map { line[$0...] } ?? line[0...]
        if valueBytes.first == 0x20 {
            valueBytes = valueBytes.dropFirst()
        }
        guard let field = String(bytes: fieldBytes, encoding: .utf8),
              let value = String(bytes: valueBytes, encoding: .utf8) else {
            throw ServerSentEventError.invalidUTF8
        }

        switch field {
        case "event":
            eventName = value
        case "data":
            dataLines.append(value)
        case "id":
            guard !value.utf8.contains(0) else { return [] }
            eventID = value
        case "retry":
            guard let retry = UInt64(value) else {
                throw ServerSentEventError.invalidRetryField
            }
            retryMilliseconds = retry
        default:
            break
        }
        return []
    }

    private mutating func dispatch() -> [ServerSentEvent] {
        defer {
            eventBytes = 0
            eventName = nil
            eventID = nil
            dataLines.removeAll(keepingCapacity: true)
            retryMilliseconds = nil
        }
        guard !dataLines.isEmpty else { return [] }
        return [ServerSentEvent(
            event: eventName ?? "message",
            id: eventID,
            data: dataLines.joined(separator: "\n"),
            retryMilliseconds: retryMilliseconds
        )]
    }
}

/// A single-pass async sequence of bounded Server-Sent Events.
public struct ServerSentEventStream: AsyncSequence, Sendable {
    public typealias Element = ServerSentEvent

    private let bytes: HTTPByteStream
    private let maximumEventBytes: Int

    public var metadata: HTTPResponseMetadata { bytes.metadata }
    public var statusCode: Int { bytes.statusCode }
    public var url: URL? { bytes.url }
    public var headers: [String: String] { bytes.headers }

    public func value(forHTTPHeaderField name: String) -> String? {
        bytes.value(forHTTPHeaderField: name)
    }

    public init(
        bytes: HTTPByteStream,
        maximumEventBytes: Int = ServerSentEventParser.defaultMaximumEventBytes
    ) {
        self.bytes = bytes
        self.maximumEventBytes = Swift.max(1, maximumEventBytes)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private var source: HTTPByteStream.AsyncIterator
        private var parser: ServerSentEventParser
        private var buffered: [ServerSentEvent] = []
        private var bufferedIndex = 0
        private var finished = false

        fileprivate init(
            source: HTTPByteStream.AsyncIterator,
            maximumEventBytes: Int
        ) {
            self.source = source
            parser = ServerSentEventParser(
                maximumEventBytes: maximumEventBytes
            )
        }

        public mutating func next() async throws -> ServerSentEvent? {
            while true {
                if bufferedIndex < buffered.count {
                    defer { bufferedIndex += 1 }
                    return buffered[bufferedIndex]
                }
                buffered.removeAll(keepingCapacity: true)
                bufferedIndex = 0
                guard !finished else { return nil }

                if let byte = try await source.next() {
                    buffered = try parser.append(byte)
                    continue
                }
                buffered = try parser.finish()
                finished = true
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            source: bytes.makeAsyncIterator(),
            maximumEventBytes: maximumEventBytes
        )
    }

    /// Cancels the underlying HTTP byte stream.
    public func cancel() {
        bytes.cancel()
    }
}
