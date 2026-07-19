import Foundation

/// Errors raised while consuming a bounded HTTP byte stream.
public enum HTTPByteStreamError: LocalizedError, Equatable, Sendable {
    case responseBodyTooLarge(maximumBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .responseBodyTooLarge(let maximumBytes):
            return "The response body exceeded the maximum of \(maximumBytes) bytes."
        }
    }
}

/// A single-pass stream of bytes returned by an HTTP response.
///
/// The response metadata is available before the first byte is consumed. A
/// URLSession-backed stream does not buffer the response in memory; cancelling
/// the consuming task cancels the underlying URL session task.
public struct HTTPByteStream: AsyncSequence, Sendable {
    public typealias Element = UInt8

    /// The HTTP response metadata received before the body stream began.
    public let metadata: HTTPResponseMetadata

    public var statusCode: Int { metadata.statusCode }
    public var url: URL? { metadata.url }
    public var headers: [String: String] { metadata.headers }

    public func value(forHTTPHeaderField name: String) -> String? {
        metadata.value(forHTTPHeaderField: name)
    }

    private enum Storage: Sendable {
        case urlSession(URLSession.AsyncBytes)
        case data(Data)
    }

    private let storage: Storage
    private let lifecycle: Lifecycle?
    private let maximumBytes: Int?

    fileprivate final class Lifecycle: @unchecked Sendable {
        private let finish: @Sendable (NetworkActivityOutcome) -> Void

        init(
            finish: @escaping @Sendable (NetworkActivityOutcome) -> Void
        ) {
            self.finish = finish
        }

        func complete(_ outcome: NetworkActivityOutcome) {
            finish(outcome)
        }

        deinit {
            finish(.cancelled)
        }
    }

    init(
        bytes: URLSession.AsyncBytes,
        metadata: HTTPResponseMetadata,
        finish: (@Sendable (NetworkActivityOutcome) -> Void)? = nil,
        maximumBytes: Int? = nil
    ) {
        storage = .urlSession(bytes)
        self.metadata = metadata
        lifecycle = finish.map(Lifecycle.init(finish:))
        self.maximumBytes = maximumBytes
    }

    /// Creates a finite in-memory stream for deterministic adapters and test
    /// doubles. Production callers should prefer the URLSession-backed stream
    /// returned by ``APIClient/stream(_:)`` for large responses.
    public init(
        data: Data,
        metadata: HTTPResponseMetadata,
        maximumBytes: Int? = nil
    ) {
        storage = .data(data)
        self.metadata = metadata
        lifecycle = nil
        self.maximumBytes = maximumBytes
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate enum IteratorStorage {
            case urlSession(URLSession.AsyncBytes.Iterator)
            case data(Data.Iterator)
        }

        private var iterator: IteratorStorage
        private let lifecycle: Lifecycle?
        private let maximumBytes: Int?
        private let cancelUnderlying: (@Sendable () -> Void)?
        private var bytesConsumed = 0

        fileprivate init(
            iterator: IteratorStorage,
            lifecycle: Lifecycle?,
            maximumBytes: Int?,
            cancelUnderlying: (@Sendable () -> Void)?
        ) {
            self.iterator = iterator
            self.lifecycle = lifecycle
            self.maximumBytes = maximumBytes
            self.cancelUnderlying = cancelUnderlying
        }

        public mutating func next() async throws -> UInt8? {
            do {
                let value: UInt8?
                switch iterator {
                case .urlSession(var iterator):
                    value = try await iterator.next()
                    self.iterator = .urlSession(iterator)
                case .data(var iterator):
                    value = iterator.next()
                    self.iterator = .data(iterator)
                }
                if value != nil, let maximumBytes {
                    guard bytesConsumed < maximumBytes else {
                        cancelUnderlying?()
                        let error = HTTPByteStreamError.responseBodyTooLarge(
                            maximumBytes: maximumBytes
                        )
                        throw error
                    }
                    bytesConsumed += 1
                }
                if value == nil {
                    lifecycle?.complete(.succeeded)
                }
                return value
            } catch {
                lifecycle?.complete(
                    Task.isCancelled || error is CancellationError
                        ? .cancelled
                        : .failed
                )
                throw error
            }
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        switch storage {
        case .urlSession(let bytes):
            return AsyncIterator(
                iterator: .urlSession(bytes.makeAsyncIterator()),
                lifecycle: lifecycle,
                maximumBytes: maximumBytes,
                cancelUnderlying: { bytes.task.cancel() }
            )
        case .data(let data):
            return AsyncIterator(
                iterator: .data(data.makeIterator()),
                lifecycle: lifecycle,
                maximumBytes: maximumBytes,
                cancelUnderlying: nil
            )
        }
    }

    /// Cancels the underlying URL session task when this is a URLSession-backed
    /// stream. This is a no-op for a finite in-memory stream.
    public func cancel() {
        if case .urlSession(let bytes) = storage {
            bytes.task.cancel()
        }
        lifecycle?.complete(.cancelled)
    }
}
