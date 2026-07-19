import Foundation

/// A single-pass stream of bytes returned by an HTTP response.
///
/// The response metadata is available before the first byte is consumed. The
/// stream does not buffer the response in memory; cancellation of the task
/// consuming the sequence cancels the underlying URL session task.
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

    private let bytes: URLSession.AsyncBytes
    private let lifecycle: Lifecycle?

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
        finish: (@Sendable (NetworkActivityOutcome) -> Void)? = nil
    ) {
        self.bytes = bytes
        self.metadata = metadata
        lifecycle = finish.map(Lifecycle.init(finish:))
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private var iterator: URLSession.AsyncBytes.Iterator
        private let lifecycle: Lifecycle?

        fileprivate init(
            iterator: URLSession.AsyncBytes.Iterator,
            lifecycle: Lifecycle?
        ) {
            self.iterator = iterator
            self.lifecycle = lifecycle
        }

        public mutating func next() async throws -> UInt8? {
            do {
                let value = try await iterator.next()
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
        AsyncIterator(
            iterator: bytes.makeAsyncIterator(),
            lifecycle: lifecycle
        )
    }

    /// Cancels the underlying URL session task.
    ///
    /// Consuming-task cancellation remains the recommended way to stop a
    /// stream. This method is useful when a stream is handed across a
    /// component boundary and ownership needs to be ended explicitly.
    public func cancel() {
        bytes.task.cancel()
        lifecycle?.complete(.cancelled)
    }
}
