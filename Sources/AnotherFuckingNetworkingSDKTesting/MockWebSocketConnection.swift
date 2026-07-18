import Foundation
import AnotherFuckingNetworkingSDK

/// A single operation captured by ``MockWebSocketConnection``.
public struct RecordedWebSocketOperation: Equatable, Sendable {
    /// The kind of WebSocket operation that was performed.
    public enum Operation: Equatable, Sendable {
        case send(WebSocketMessage)
        case receive
        case ping
        case close(WebSocketClose)
    }

    /// A zero-based identifier that preserves invocation order.
    public let sequenceID: Int

    /// The recorded operation and any associated payload.
    public let operation: Operation

    public init(sequenceID: Int, operation: Operation) {
        self.sequenceID = sequenceID
        self.operation = operation
    }
}

/// A convenience name for the operation stored by
/// ``RecordedWebSocketOperation``.
public typealias MockWebSocketOperation = RecordedWebSocketOperation.Operation

/// A deterministic, actor-isolated test double for a WebSocket connection.
///
/// Incoming messages and pending receivers are matched in FIFO order. Send and
/// ping results are also consumed in FIFO order, defaulting to success when no
/// result has been queued.
public actor MockWebSocketConnection: WebSocketConnectionProtocol {
    public nonisolated let url: URL
    public nonisolated let negotiatedSubprotocol: String?

    /// The connection's current lifecycle state.
    public private(set) var state: WebSocketConnectionState = .open

    /// Every accepted connection operation in invocation order.
    public private(set) var recordedOperations: [
        RecordedWebSocketOperation
    ] = []

    /// Messages passed to successful or failed send attempts.
    public var sentMessages: [WebSocketMessage] {
        recordedOperations.compactMap { record in
            guard case .send(let message) = record.operation else {
                return nil
            }
            return message
        }
    }

    /// The number of accepted ping attempts.
    public var pingCount: Int {
        recordedOperations.reduce(into: 0) { count, record in
            if case .ping = record.operation {
                count += 1
            }
        }
    }

    /// Details from the locally requested or terminal close, if available.
    public private(set) var closeDetails: WebSocketClose?

    /// The number of receive calls currently waiting for input.
    public var pendingReceiveCount: Int {
        receiveWaiters.count
    }

    private var incomingResults: [
        Result<WebSocketMessage, any Error>
    ]
    private var sendResults: [Result<Void, any Error>] = []
    private var pingResults: [Result<Void, any Error>] = []
    private var receiveWaiters: [ReceiveWaiter] = []
    private var terminalError: (any Error)?
    private var nextSequenceID = 0

    /// Creates an open mock connection.
    ///
    /// - Parameters:
    ///   - url: The endpoint exposed by the connection.
    ///   - negotiatedSubprotocol: The subprotocol selected by the mock peer.
    ///   - incoming: Results initially available to receive calls.
    public init(
        url: URL = URL(string: "wss://mock.invalid")!,
        negotiatedSubprotocol: String? = nil,
        incoming: [Result<WebSocketMessage, any Error>] = []
    ) {
        self.url = url
        self.negotiatedSubprotocol = negotiatedSubprotocol
        incomingResults = incoming
    }

    // MARK: Queue configuration

    /// Enqueues one incoming message or error.
    public func enqueueIncoming(
        _ result: Result<WebSocketMessage, any Error>
    ) {
        guard isOpen else { return }

        if receiveWaiters.isEmpty {
            incomingResults.append(result)
        } else {
            let waiter = receiveWaiters.removeFirst()
            waiter.continuation.resume(with: result)
        }
    }

    /// Enqueues one incoming text or binary message.
    public func enqueueIncoming(_ message: WebSocketMessage) {
        enqueueIncoming(.success(message))
    }

    /// Enqueues one incoming text message.
    public func enqueueIncoming(text: String) {
        enqueueIncoming(.text(text))
    }

    /// Enqueues one incoming binary message.
    public func enqueueIncoming(data: Data) {
        enqueueIncoming(.binary(data))
    }

    /// Enqueues one non-terminal receive failure.
    public func enqueueIncoming(error: any Error) {
        enqueueIncoming(.failure(error))
    }

    /// Enqueues the result of a future send operation.
    public func enqueueSendResult(_ result: Result<Void, any Error>) {
        sendResults.append(result)
    }

    /// Enqueues the result of a future ping operation.
    public func enqueuePingResult(_ result: Result<Void, any Error>) {
        pingResults.append(result)
    }

    // MARK: Connection operations

    public func send(_ message: WebSocketMessage) async throws {
        try Task.checkCancellation()
        try requireOpen()

        record(.send(message))
        let result = sendResults.isEmpty
            ? Result<Void, any Error>.success(())
            : sendResults.removeFirst()
        _ = try resolve(result)
    }

    public func receive() async throws -> WebSocketMessage {
        try Task.checkCancellation()
        try requireOpen()
        record(.receive)

        if !incomingResults.isEmpty {
            return try resolve(incomingResults.removeFirst())
        }

        let waiterID = UUID()
        do {
            let message = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<
                        WebSocketMessage,
                        any Error
                    >) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        receiveWaiters.append(ReceiveWaiter(
                            id: waiterID,
                            continuation: continuation
                        ))
                    }
                }
            } onCancel: {
                Task { await self.cancelReceive(waiterID) }
            }
            try Task.checkCancellation()
            return message
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    public func ping() async throws {
        try Task.checkCancellation()
        try requireOpen()

        record(.ping)
        let result = pingResults.isEmpty
            ? Result<Void, any Error>.success(())
            : pingResults.removeFirst()
        _ = try resolve(result)
    }

    public func close(
        code: WebSocketCloseCode,
        reason: String?
    ) async throws {
        try Task.checkCancellation()
        let close = try Self.validatedClose(code: code, reason: reason)

        guard isOpen else { return }

        record(.close(close))
        closeDetails = close
        state = .closing
        incomingResults.removeAll(keepingCapacity: true)
        drainReceiveWaiters(throwing: WebSocketError.connectionClosing)
    }

    // MARK: Terminal state management

    /// Finishes the connection and rejects pending and future I/O as closed.
    public func finish(with close: WebSocketClose? = nil) {
        guard terminalError == nil else { return }
        guard !isClosed else { return }

        let finalClose = close ?? closeDetails
        closeDetails = finalClose
        state = .closed(finalClose)
        clearQueuedResults()
        drainReceiveWaiters(
            throwing: WebSocketError.connectionClosed(finalClose)
        )
    }

    /// Finishes using a close code and optional binary reason.
    public func finish(
        with code: WebSocketCloseCode,
        reason: Data? = nil
    ) {
        finish(with: WebSocketClose(code: code, reason: reason))
    }

    /// Fails the connection and uses the same terminal error for pending and
    /// future I/O.
    public func fail(with error: any Error) {
        guard terminalError == nil else { return }
        guard !isClosed else { return }

        terminalError = error
        state = .closed(closeDetails)
        clearQueuedResults()
        drainReceiveWaiters(throwing: error)
    }

    /// Clears only the unified operation history and restarts sequence IDs.
    public func clearRecordedOperations() {
        recordedOperations.removeAll(keepingCapacity: true)
        nextSequenceID = 0
    }

    /// Returns the mock to a fresh open state.
    ///
    /// Pending receivers are cancelled before all queued results and recorded
    /// operations are cleared.
    public func reset() {
        drainReceiveWaiters(throwing: CancellationError())
        clearQueuedResults()
        clearRecordedOperations()
        terminalError = nil
        closeDetails = nil
        state = .open
    }

    // MARK: Private helpers

    private var isOpen: Bool {
        guard terminalError == nil else { return false }
        if case .open = state { return true }
        return false
    }

    private var isClosed: Bool {
        if case .closed = state { return true }
        return false
    }

    private func requireOpen() throws {
        if let terminalError {
            throw terminalError
        }

        switch state {
        case .open:
            return
        case .closing:
            throw WebSocketError.connectionClosing
        case .closed(let close):
            throw WebSocketError.connectionClosed(close)
        }
    }

    private func record(_ operation: MockWebSocketOperation) {
        recordedOperations.append(RecordedWebSocketOperation(
            sequenceID: nextSequenceID,
            operation: operation
        ))
        nextSequenceID += 1
    }

    private func resolve<Value: Sendable>(
        _ result: Result<Value, any Error>
    ) throws -> Value {
        do {
            let value = try result.get()
            try Task.checkCancellation()
            return value
        } catch {
            if Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw error
        }
    }

    private func cancelReceive(_ id: UUID) {
        guard let index = receiveWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = receiveWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func drainReceiveWaiters(throwing error: any Error) {
        let waiters = receiveWaiters
        receiveWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.continuation.resume(throwing: error)
        }
    }

    private func clearQueuedResults() {
        incomingResults.removeAll(keepingCapacity: true)
        sendResults.removeAll(keepingCapacity: true)
        pingResults.removeAll(keepingCapacity: true)
    }

    private static func validatedClose(
        code: WebSocketCloseCode,
        reason: String?
    ) throws -> WebSocketClose {
        let rawValue = code.rawValue
        let isStandard = (1_000...1_014).contains(rawValue)
            && ![1_004, 1_005, 1_006].contains(rawValue)
        guard isStandard || (3_000...4_999).contains(rawValue) else {
            throw WebSocketError.invalidCloseCode(rawValue)
        }

        let reasonData = reason.map { Data($0.utf8) }
        let maximumReasonBytes = 123
        if let reasonData, reasonData.count > maximumReasonBytes {
            throw WebSocketError.closeReasonTooLong(
                maximumBytes: maximumReasonBytes,
                actualBytes: reasonData.count
            )
        }

        return WebSocketClose(code: code, reason: reasonData)
    }
}

private extension MockWebSocketConnection {
    struct ReceiveWaiter {
        let id: UUID
        let continuation: CheckedContinuation<WebSocketMessage, any Error>
    }
}
