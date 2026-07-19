import Foundation

/// Errors raised while parsing a bounded JSON Lines stream.
public enum JSONLinesError: LocalizedError, Equatable, Sendable {
    case lineTooLarge(maximumBytes: Int, actualBytes: Int)
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .lineTooLarge(let maximumBytes, let actualBytes):
            return "The JSON Lines record exceeded the \(maximumBytes)-byte limit (received \(actualBytes) bytes)."
        case .decodingFailed:
            return "The JSON Lines record could not be decoded."
        }
    }
}

/// Incremental, bounded parser for newline-delimited JSON values.
public struct JSONLinesParser<Value: Decodable & Sendable>: Sendable {
    public static var defaultMaximumLineBytes: Int { 256 * 1_024 }

    private let maximumLineBytes: Int
    private var line: [UInt8] = []
    private var pendingCarriageReturn = false

    public init(
        maximumLineBytes: Int = Self.defaultMaximumLineBytes
    ) {
        self.maximumLineBytes = Swift.max(1, maximumLineBytes)
    }

    /// Appends bytes and returns every complete decoded value made available.
    public mutating func append(_ data: Data) throws -> [Value] {
        var values: [Value] = []
        for byte in data {
            if let value = try append(byte) {
                values.append(value)
            }
        }
        return values
    }

    /// Finishes the stream, decoding a final unterminated line if present.
    public mutating func finish() throws -> [Value] {
        guard !line.isEmpty else { return [] }
        defer { line.removeAll(keepingCapacity: true) }
        return [try decodeLine()]
    }

    fileprivate mutating func append(_ byte: UInt8) throws -> Value? {
        if pendingCarriageReturn {
            pendingCarriageReturn = false
            if byte == 0x0A {
                return nil
            }
        }

        if byte == 0x0A || byte == 0x0D {
            if byte == 0x0D {
                pendingCarriageReturn = true
            }
            guard !line.isEmpty else { return nil }
            defer { line.removeAll(keepingCapacity: true) }
            return try decodeLine()
        }

        line.append(byte)
        guard line.count <= maximumLineBytes else {
            throw JSONLinesError.lineTooLarge(
                maximumBytes: maximumLineBytes,
                actualBytes: line.count
            )
        }
        return nil
    }

    private func decodeLine() throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(line))
        } catch {
            throw JSONLinesError.decodingFailed
        }
    }
}

/// A single-pass async sequence of bounded, typed JSON Lines records.
public struct JSONLinesStream<Value: Decodable & Sendable>:
    AsyncSequence,
    Sendable
{
    public typealias Element = Value

    private let bytes: HTTPByteStream
    private let maximumLineBytes: Int

    public var metadata: HTTPResponseMetadata { bytes.metadata }
    public var statusCode: Int { bytes.statusCode }
    public var url: URL? { bytes.url }
    public var headers: [String: String] { bytes.headers }

    public init(
        bytes: HTTPByteStream,
        maximumLineBytes: Int = JSONLinesParser<Value>.defaultMaximumLineBytes
    ) {
        self.bytes = bytes
        self.maximumLineBytes = Swift.max(1, maximumLineBytes)
    }

    public func value(forHTTPHeaderField name: String) -> String? {
        bytes.value(forHTTPHeaderField: name)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private var source: HTTPByteStream.AsyncIterator
        private var parser: JSONLinesParser<Value>
        private var buffered: [Value] = []
        private var bufferedIndex = 0
        private var finished = false

        fileprivate init(
            source: HTTPByteStream.AsyncIterator,
            maximumLineBytes: Int
        ) {
            self.source = source
            parser = JSONLinesParser(maximumLineBytes: maximumLineBytes)
        }

        public mutating func next() async throws -> Value? {
            while true {
                if bufferedIndex < buffered.count {
                    defer { bufferedIndex += 1 }
                    return buffered[bufferedIndex]
                }
                buffered.removeAll(keepingCapacity: true)
                bufferedIndex = 0
                guard !finished else { return nil }

                if let byte = try await source.next() {
                    if let value = try parser.append(byte) {
                        buffered = [value]
                    }
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
            maximumLineBytes: maximumLineBytes
        )
    }

    /// Cancels the underlying HTTP byte stream.
    public func cancel() {
        bytes.cancel()
    }
}

public extension APIClientStreamingProtocol {
    /// Opens a typed newline-delimited JSON stream over the existing HTTP
    /// transport. Status and retry policies are resolved before this returns.
    func streamJSONLines<R: HTTPRequest, Value: Decodable & Sendable>(
        _ request: R,
        as _: Value.Type,
        maximumLineBytes: Int = JSONLinesParser<Value>.defaultMaximumLineBytes
    ) async throws -> JSONLinesStream<Value> {
        JSONLinesStream(
            bytes: try await stream(request),
            maximumLineBytes: maximumLineBytes
        )
    }
}
