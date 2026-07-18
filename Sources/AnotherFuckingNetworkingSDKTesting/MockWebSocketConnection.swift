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
/// Injected incoming messages are retained in a bounded FIFO until consumed.
/// Like the production connection, the mock accepts only one active receive,
/// preserves messages accepted before terminal closure, and fails rather than
/// dropping data when its inbound limits are exceeded. Send and ping results
/// are consumed in FIFO order, defaulting to success when none is queued.
public actor MockWebSocketConnection: WebSocketConnectionProtocol {
    public nonisolated let url: URL
    public nonisolated let negotiatedSubprotocol: String?
    public nonisolated let inboundBufferingPolicy:
        WebSocketInboundBufferingPolicy

    /// The connection's current lifecycle state.
    public private(set) var state: WebSocketConnectionState = .open

    public nonisolated var states: WebSocketConnectionStates {
        let stateBroadcaster = self.stateBroadcaster
        return WebSocketConnectionStates(stream: {
            stateBroadcaster.stream()
        })
    }

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
        receiveWaiter == nil ? 0 : 1
    }

    /// Complete messages currently retained for future receive calls.
    public var bufferedMessageCount: Int {
        incomingResults.count
    }

    /// Aggregate UTF-8 text or binary payload bytes currently retained.
    public private(set) var bufferedByteCount = 0

    private var incomingResults: FIFOQueue<
        Result<WebSocketMessage, any Error>
    >
    private var sendResults = FIFOQueue<Result<Void, any Error>>()
    private var pingResults = FIFOQueue<Result<Void, any Error>>()
    private var receiveWaiter: ReceiveWaiter?
    private var terminalReceiveError: (any Error)?
    private var nextSequenceID = 0
    private var lifecycleGeneration = 0
    private nonisolated let stateBroadcaster = LatestValueBroadcaster<
        WebSocketConnectionState
    >(.open)

    /// Creates a mock connection with the default inbound buffering policy.
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
        let initial = Self.prepareInitialInbound(
            incoming,
            policy: .default
        )
        self.url = url
        self.negotiatedSubprotocol = negotiatedSubprotocol
        inboundBufferingPolicy = .default
        incomingResults = FIFOQueue(initial.results)
        bufferedByteCount = initial.bufferedByteCount
        terminalReceiveError = initial.terminalError
        if initial.terminalError != nil {
            state = .closed(nil)
            stateBroadcaster.finish(with: .closed(nil))
        }
    }

    /// Creates a mock connection with production-equivalent inbound buffering
    /// limits.
    ///
    /// Both limits must be greater than zero. Initial incoming results are
    /// accepted in order until a failure or overflow terminalizes the mock.
    public init(
        url: URL = URL(string: "wss://mock.invalid")!,
        negotiatedSubprotocol: String? = nil,
        inboundBufferingPolicy: WebSocketInboundBufferingPolicy,
        incoming: [Result<WebSocketMessage, any Error>] = []
    ) throws {
        guard inboundBufferingPolicy.maximumMessages > 0,
              inboundBufferingPolicy.maximumBytes > 0 else {
            throw WebSocketError.invalidInboundBufferingPolicy(
                inboundBufferingPolicy
            )
        }
        let initial = Self.prepareInitialInbound(
            incoming,
            policy: inboundBufferingPolicy
        )
        self.url = url
        self.negotiatedSubprotocol = negotiatedSubprotocol
        self.inboundBufferingPolicy = inboundBufferingPolicy
        incomingResults = FIFOQueue(initial.results)
        bufferedByteCount = initial.bufferedByteCount
        terminalReceiveError = initial.terminalError
        if initial.terminalError != nil {
            state = .closed(nil)
            stateBroadcaster.finish(with: .closed(nil))
        }
    }

    // MARK: Queue configuration

    /// Enqueues one incoming message or error.
    public func enqueueIncoming(
        _ result: Result<WebSocketMessage, any Error>
    ) {
        guard canAcceptIncoming else { return }

        switch result {
        case .success(let message):
            if let receiveWaiter {
                self.receiveWaiter = nil
                receiveWaiter.continuation.resume(returning: message)
            } else if let overflow = buffer(message) {
                terminalize(
                    receiveError: WebSocketError.inboundBufferOverflow(
                        overflow
                    )
                )
            }

        case .failure(let error):
            terminalize(receiveError: error)
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

    /// Injects one receive failure. The failure immediately closes the mock;
    /// already accepted messages remain drainable before it is surfaced.
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
        try cancelIfNeeded()
        try requireOpen()

        record(.send(message))
        let result = sendResults.isEmpty
            ? Result<Void, any Error>.success(())
            : sendResults.popFirst()!
        _ = try resolveOperation(result)
    }

    public func receive() async throws -> WebSocketMessage {
        try cancelIfNeeded()
        if case .closing = state {
            throw WebSocketError.connectionClosing
        }
        guard receiveWaiter == nil else {
            throw WebSocketError.concurrentReceive
        }

        if !incomingResults.isEmpty {
            record(.receive)
            let result = incomingResults.popFirst()!
            if case .success(let message) = result {
                bufferedByteCount -= message.inboundBufferedByteCount
            }
            return try resolveOperation(result)
        }

        if let terminalReceiveError {
            throw terminalReceiveError
        }
        if case .closed(let close) = state {
            throw WebSocketError.connectionClosed(close)
        }

        record(.receive)
        let waiterID = UUID()
        let generation = lifecycleGeneration
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
                        receiveWaiter = ReceiveWaiter(
                            id: waiterID,
                            continuation: continuation
                        )
                    }
                }
            } onCancel: {
                Task { await self.cancelReceive(waiterID) }
            }
            try Task.checkCancellation()
            return message
        } catch {
            if Task.isCancelled || error is CancellationError {
                if generation == lifecycleGeneration {
                    closeAfterOperationFailure(
                        receiveError: WebSocketError.connectionClosed(
                            closeDetails
                        )
                    )
                }
                throw CancellationError()
            }
            if generation == lifecycleGeneration {
                closeAfterOperationFailure(receiveError: error)
            }
            throw error
        }
    }

    public func ping() async throws {
        try cancelIfNeeded()
        try requireOpen()

        record(.ping)
        let result = pingResults.isEmpty
            ? Result<Void, any Error>.success(())
            : pingResults.popFirst()!
        _ = try resolveOperation(result)
    }

    public func close(
        code: WebSocketCloseCode,
        reason: String?
    ) async throws {
        let close = try Self.validatedClose(code: code, reason: reason)

        guard isOpen else { return }

        record(.close(close))
        closeDetails = close
        state = .closing
        stateBroadcaster.publish(.closing)
    }

    // MARK: Terminal state management

    /// Finishes the connection. Accepted messages remain drainable before
    /// pending and future receive calls observe closure.
    public func finish(with close: WebSocketClose? = nil) {
        let finalClose = close ?? closeDetails
        if isClosed {
            guard let finalClose, closeDetails != finalClose else { return }
            closeDetails = finalClose
            terminalReceiveError = Self.terminalError(
                preserving: terminalReceiveError,
                close: finalClose
            )
            state = .closed(finalClose)
            stateBroadcaster.finish(with: .closed(finalClose))
            return
        }

        closeDetails = finalClose
        state = .closed(finalClose)
        let receiveError = WebSocketError.connectionClosed(finalClose)
        if terminalReceiveError == nil {
            terminalReceiveError = receiveError
        }
        stateBroadcaster.finish(with: .closed(finalClose))
        clearQueuedOperationResults()
        drainReceiveWaiters(throwing: terminalReceiveError ?? receiveError)
    }

    /// Finishes using a close code and optional binary reason.
    public func finish(
        with code: WebSocketCloseCode,
        reason: Data? = nil
    ) {
        finish(with: WebSocketClose(code: code, reason: reason))
    }

    /// Fails the connection. Accepted messages drain before the error is used
    /// for pending and future receive calls.
    public func fail(with error: any Error) {
        guard !isClosed else { return }
        terminalize(receiveError: error)
    }

    /// Clears only the unified operation history. Sequence IDs remain
    /// monotonic for the connection's lifetime.
    public func clearRecordedOperations() {
        recordedOperations.removeAll(keepingCapacity: true)
    }

    /// Returns the mock to a fresh open state.
    ///
    /// Pending receivers are cancelled before all queued results and recorded
    /// operations are cleared.
    public func reset() {
        lifecycleGeneration += 1
        drainReceiveWaiters(throwing: CancellationError())
        clearQueuedResults()
        clearRecordedOperations()
        terminalReceiveError = nil
        closeDetails = nil
        state = .open
        stateBroadcaster.reset(to: .open)
    }

    // MARK: Private helpers

    private var isOpen: Bool {
        if case .open = state { return true }
        return false
    }

    private var canAcceptIncoming: Bool {
        switch state {
        case .open, .closing:
            return terminalReceiveError == nil
        case .closed:
            return false
        }
    }

    private var isClosed: Bool {
        if case .closed = state { return true }
        return false
    }

    private func requireOpen() throws {
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

    private func resolveOperation<Value: Sendable>(
        _ result: Result<Value, any Error>
    ) throws -> Value {
        do {
            let value = try result.get()
            try cancelIfNeeded()
            return value
        } catch {
            if Task.isCancelled || error is CancellationError {
                closeAfterOperationFailure(
                    receiveError: WebSocketError.connectionClosed(closeDetails)
                )
                throw CancellationError()
            }
            closeAfterOperationFailure(receiveError: error)
            throw error
        }
    }

    private func cancelIfNeeded() throws {
        guard Task.isCancelled else { return }
        closeAfterOperationFailure(
            receiveError: WebSocketError.connectionClosed(closeDetails)
        )
        throw CancellationError()
    }

    private func closeAfterOperationFailure(receiveError: any Error) {
        guard !isClosed else { return }
        terminalReceiveError = receiveError
        state = .closed(closeDetails)
        stateBroadcaster.finish(with: .closed(closeDetails))
        clearQueuedOperationResults()
        drainReceiveWaiters(throwing: receiveError)
    }

    private func cancelReceive(_ id: UUID) {
        guard let receiveWaiter, receiveWaiter.id == id else {
            return
        }
        self.receiveWaiter = nil
        terminalReceiveError = WebSocketError.connectionClosed(closeDetails)
        state = .closed(closeDetails)
        stateBroadcaster.finish(with: .closed(closeDetails))
        clearQueuedOperationResults()
        receiveWaiter.continuation.resume(throwing: CancellationError())
    }

    private func drainReceiveWaiters(throwing error: any Error) {
        guard let receiveWaiter else { return }
        self.receiveWaiter = nil
        receiveWaiter.continuation.resume(throwing: error)
    }

    private func clearQueuedResults() {
        incomingResults.removeAll(keepingCapacity: true)
        bufferedByteCount = 0
        clearQueuedOperationResults()
    }

    private func clearQueuedOperationResults() {
        sendResults.removeAll(keepingCapacity: true)
        pingResults.removeAll(keepingCapacity: true)
    }

    private func buffer(
        _ message: WebSocketMessage
    ) -> WebSocketInboundBufferOverflow? {
        let byteCount = message.inboundBufferedByteCount
        let exceedsMessages = incomingResults.count
            >= inboundBufferingPolicy.maximumMessages
        let exceedsBytes = byteCount > inboundBufferingPolicy.maximumBytes
            || bufferedByteCount
                > inboundBufferingPolicy.maximumBytes - byteCount
        if exceedsMessages || exceedsBytes {
            return WebSocketInboundBufferOverflow(
                policy: inboundBufferingPolicy,
                bufferedMessageCount: incomingResults.count,
                bufferedByteCount: bufferedByteCount,
                incomingMessageByteCount: byteCount
            )
        }

        incomingResults.append(.success(message))
        bufferedByteCount += byteCount
        return nil
    }

    private func terminalize(receiveError: any Error) {
        guard !isClosed else { return }
        terminalReceiveError = receiveError
        state = .closed(closeDetails)
        stateBroadcaster.finish(with: .closed(closeDetails))
        clearQueuedOperationResults()
        drainReceiveWaiters(throwing: receiveError)
    }

    private static func terminalError(
        preserving existing: (any Error)?,
        close: WebSocketClose?
    ) -> any Error {
        if let webSocketError = existing as? WebSocketError,
           case .inboundBufferOverflow = webSocketError {
            return webSocketError
        }
        return WebSocketError.connectionClosed(close)
    }

    private static func prepareInitialInbound(
        _ incoming: [Result<WebSocketMessage, any Error>],
        policy: WebSocketInboundBufferingPolicy
    ) -> InitialInbound {
        var results: [Result<WebSocketMessage, any Error>] = []
        results.reserveCapacity(min(incoming.count, policy.maximumMessages))
        var bufferedByteCount = 0
        var terminalError: (any Error)?

        for result in incoming {
            switch result {
            case .success(let message):
                let byteCount = message.inboundBufferedByteCount
                let exceedsMessages = results.count >= policy.maximumMessages
                let exceedsBytes = byteCount > policy.maximumBytes
                    || bufferedByteCount > policy.maximumBytes - byteCount
                if exceedsMessages || exceedsBytes {
                    terminalError = WebSocketError.inboundBufferOverflow(
                        WebSocketInboundBufferOverflow(
                            policy: policy,
                            bufferedMessageCount: results.count,
                            bufferedByteCount: bufferedByteCount,
                            incomingMessageByteCount: byteCount
                        )
                    )
                } else {
                    results.append(result)
                    bufferedByteCount += byteCount
                }

            case .failure(let error):
                terminalError = error
            }

            if terminalError != nil {
                break
            }
        }

        return InitialInbound(
            results: results,
            bufferedByteCount: bufferedByteCount,
            terminalError: terminalError
        )
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
    struct InitialInbound {
        let results: [Result<WebSocketMessage, any Error>]
        let bufferedByteCount: Int
        let terminalError: (any Error)?
    }

    struct ReceiveWaiter {
        let id: UUID
        let continuation: CheckedContinuation<WebSocketMessage, any Error>
    }
}

private extension WebSocketMessage {
    var inboundBufferedByteCount: Int {
        switch self {
        case .text(let text):
            return text.utf8.count
        case .binary(let data):
            return data.count
        }
    }
}
