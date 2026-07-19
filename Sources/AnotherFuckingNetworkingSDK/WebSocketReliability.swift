import Foundation

/// Bounded reconnect, backoff, and heartbeat settings for an opt-in wrapper.
public struct WebSocketReliabilityPolicy: Equatable, Sendable {
    public let maximumReconnectAttempts: Int
    public let initialBackoffNanoseconds: UInt64
    public let maximumBackoffNanoseconds: UInt64
    public let backoffMultiplier: Double
    public let jitterRatio: Double
    public let heartbeatIntervalNanoseconds: UInt64?

    public init(
        maximumReconnectAttempts: Int = 3,
        initialBackoffNanoseconds: UInt64 = 250_000_000,
        maximumBackoffNanoseconds: UInt64 = 30_000_000_000,
        backoffMultiplier: Double = 2,
        jitterRatio: Double = 0.2,
        heartbeatIntervalNanoseconds: UInt64? = nil
    ) {
        self.maximumReconnectAttempts = max(0, maximumReconnectAttempts)
        self.initialBackoffNanoseconds = initialBackoffNanoseconds
        self.maximumBackoffNanoseconds = max(
            initialBackoffNanoseconds,
            maximumBackoffNanoseconds
        )
        self.backoffMultiplier = backoffMultiplier.isFinite
            ? max(1, backoffMultiplier)
            : 1
        self.jitterRatio = jitterRatio.isFinite
            ? min(1, max(0, jitterRatio))
            : 0
        self.heartbeatIntervalNanoseconds = heartbeatIntervalNanoseconds
            .flatMap { $0 > 0 ? $0 : nil }
    }

    fileprivate func delayNanoseconds(
        afterAttempt attempt: Int,
        randomUnitValue: Double
    ) -> UInt64 {
        guard attempt > 0, initialBackoffNanoseconds > 0 else { return 0 }
        let exponent = min(attempt - 1, 63)
        let exponential = Double(initialBackoffNanoseconds)
            * pow(backoffMultiplier, Double(exponent))
        let bounded = min(
            Double(maximumBackoffNanoseconds),
            max(0, exponential)
        )
        let unit = min(1, max(0, randomUnitValue))
        let jitter = 1 + ((unit * 2) - 1) * jitterRatio
        let delayed = min(
            Double(maximumBackoffNanoseconds),
            max(0, bounded * jitter)
        )
        return UInt64(delayed.rounded(.towardZero))
    }
}

public typealias WebSocketReliabilitySleeper =
    @Sendable (UInt64) async throws -> Void
public typealias WebSocketReliabilityRandom = @Sendable () -> Double
public typealias WebSocketSessionRestorer = @Sendable (
    any WebSocketConnectionProtocol
) async throws -> Void

/// Context for application-specific subscription or cursor restoration.
public struct WebSocketReconnectContext: Equatable, Sendable {
    /// The one-based reconnect attempt that is about to be opened.
    public let attempt: Int
    /// The URL of the connection that failed or was replaced.
    public let previousURL: URL
    /// The subprotocol negotiated by the previous connection, if any.
    public let previousSubprotocol: String?

    public init(
        attempt: Int,
        previousURL: URL,
        previousSubprotocol: String? = nil
    ) {
        self.attempt = max(1, attempt)
        self.previousURL = previousURL
        self.previousSubprotocol = previousSubprotocol
    }
}

public typealias WebSocketSessionRestorerWithContext = @Sendable (
    any WebSocketConnectionProtocol,
    WebSocketReconnectContext
) async throws -> Void

/// A client wrapper that adds bounded reconnect and optional heartbeat policy.
///
/// The underlying `WebSocketClientProtocol` remains responsible for one
/// handshake and one bounded connection. This wrapper retries only transport,
/// close, and handshake failures; it never retries application messages that
/// were accepted by Foundation. Session restoration is explicit so callers can
/// resubscribe or reauthenticate after reconnecting.
public struct WebSocketReliabilityClient<BaseClient: WebSocketClientProtocol>:
    WebSocketClientProtocol,
    Sendable {
    private let baseClient: BaseClient
    private let policy: WebSocketReliabilityPolicy
    private let sleeper: WebSocketReliabilitySleeper
    private let random: WebSocketReliabilityRandom
    private let restorer: WebSocketSessionRestorer?
    private let restorerWithContext: WebSocketSessionRestorerWithContext?

    public init(
        client: BaseClient,
        policy: WebSocketReliabilityPolicy = .init(),
        sleeper: @escaping WebSocketReliabilitySleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        random: @escaping WebSocketReliabilityRandom = {
            Double.random(in: 0...1)
        },
        restorer: WebSocketSessionRestorer? = nil,
        restorerWithContext: WebSocketSessionRestorerWithContext? = nil
    ) {
        baseClient = client
        self.policy = policy
        self.sleeper = sleeper
        self.random = random
        self.restorer = restorer
        self.restorerWithContext = restorerWithContext
    }

    public func connect<R: WebSocketRequest>(
        _ request: R
    ) async throws -> any WebSocketConnectionProtocol {
        let initial = try await baseClient.connect(request)
        let connection = WebSocketReliabilityConnection(
            client: baseClient,
            request: request,
            initial: initial,
            policy: policy,
            sleeper: sleeper,
            random: random,
            restorer: restorer,
            restorerWithContext: restorerWithContext
        )
        await connection.startHeartbeat()
        return connection
    }
}

private final class WebSocketReliabilityStateBroadcaster: @unchecked Sendable {
    typealias Continuation = AsyncStream<WebSocketConnectionState>.Continuation

    private struct State: Sendable {
        var current: WebSocketConnectionState
        var subscribers: [UUID: Continuation] = [:]
        var finished = false
    }

    private let state: CriticalState<State>

    init(initial: WebSocketConnectionState) {
        state = CriticalState(State(current: initial))
    }

    func stream() -> AsyncStream<WebSocketConnectionState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
            [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
            let shouldFinish = state.withCriticalRegion { state in
                guard !state.finished else { return true }
                state.subscribers[id] = continuation
                continuation.yield(state.current)
                return false
            }
            if shouldFinish {
                continuation.finish()
            }
        }
    }

    func emit(_ value: WebSocketConnectionState) {
        state.withCriticalRegion { state in
            guard !state.finished else { return }
            state.current = value
            for continuation in state.subscribers.values {
                continuation.yield(value)
            }
        }
    }

    func finish(_ value: WebSocketConnectionState) {
        state.withCriticalRegion { state in
            guard !state.finished else { return }
            state.finished = true
            state.current = value
            for continuation in state.subscribers.values {
                continuation.yield(value)
                continuation.finish()
            }
            state.subscribers.removeAll(keepingCapacity: false)
        }
    }

    private func remove(_ id: UUID) {
        state.withCriticalRegion { $0.subscribers[id] = nil }
    }
}

/// A reconnecting, heartbeat-capable WebSocket connection.
public actor WebSocketReliabilityConnection<
    BaseClient: WebSocketClientProtocol,
    Request: WebSocketRequest
>: WebSocketConnectionProtocol {
    public nonisolated let url: URL
    public nonisolated let negotiatedSubprotocol: String?

    private let client: BaseClient
    private let request: Request
    private let policy: WebSocketReliabilityPolicy
    private let sleeper: WebSocketReliabilitySleeper
    private let random: WebSocketReliabilityRandom
    private let restorer: WebSocketSessionRestorer?
    private let restorerWithContext: WebSocketSessionRestorerWithContext?
    private let broadcaster: WebSocketReliabilityStateBroadcaster
    private var current: any WebSocketConnectionProtocol
    private var closedByCaller = false
    private var heartbeatTask: Task<Void, Never>?

    init(
        client: BaseClient,
        request: Request,
        initial: any WebSocketConnectionProtocol,
        policy: WebSocketReliabilityPolicy,
        sleeper: @escaping WebSocketReliabilitySleeper,
        random: @escaping WebSocketReliabilityRandom,
        restorer: WebSocketSessionRestorer?,
        restorerWithContext: WebSocketSessionRestorerWithContext?
    ) {
        self.client = client
        self.request = request
        self.policy = policy
        self.sleeper = sleeper
        self.random = random
        self.restorer = restorer
        self.restorerWithContext = restorerWithContext
        current = initial
        url = initial.url
        negotiatedSubprotocol = initial.negotiatedSubprotocol
        broadcaster = WebSocketReliabilityStateBroadcaster(initial: .open)
    }

    public var state: WebSocketConnectionState {
        get async {
            if closedByCaller {
                return .closed(nil)
            }
            return await current.state
        }
    }

    public nonisolated var states: WebSocketConnectionStates {
        WebSocketConnectionStates(stream: { [broadcaster] in
            broadcaster.stream()
        })
    }

    func startHeartbeat() {
        guard heartbeatTask == nil,
              let interval = policy.heartbeatIntervalNanoseconds else {
            return
        }
        heartbeatTask = Task { [weak self, sleeper] in
            while !Task.isCancelled {
                do {
                    try await sleeper(interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.heartbeatTick()
            }
        }
    }

    public func send(_ message: WebSocketMessage) async throws {
        try await withReconnect { connection in
            try await connection.send(message)
        }
    }

    public func receive() async throws -> WebSocketMessage {
        try await withReconnect { connection in
            try await connection.receive()
        }
    }

    public func ping() async throws {
        try await withReconnect { connection in
            try await connection.ping()
        }
    }

    public func close(
        code: WebSocketCloseCode,
        reason: String?
    ) async throws {
        closedByCaller = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        try await current.close(code: code, reason: reason)
        broadcaster.finish(.closed(nil))
    }

    private func heartbeatTick() async {
        guard !closedByCaller else { return }
        do {
            try await ping()
        } catch {
            // `withReconnect` closes and finishes the lifecycle when the
            // bounded policy is exhausted. The heartbeat task itself should
            // not become an unstructured error source.
        }
    }

    private func withReconnect<Value: Sendable>(
        operation: @escaping @Sendable (
            any WebSocketConnectionProtocol
        ) async throws -> Value
    ) async throws -> Value {
        var reconnectAttempts = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await operation(current)
            } catch {
                guard shouldReconnect(after: error),
                      !closedByCaller,
                      reconnectAttempts < policy.maximumReconnectAttempts else {
                    await closeAfterFailure(error)
                    throw error
                }

                reconnectAttempts += 1
                do {
                    try await reconnect(attempt: reconnectAttempts)
                } catch {
                    if reconnectAttempts >= policy.maximumReconnectAttempts {
                        await closeAfterFailure(error)
                        throw error
                    }
                }
            }
        }
    }

    private func reconnect(attempt: Int) async throws {
        let delay = policy.delayNanoseconds(
            afterAttempt: attempt,
            randomUnitValue: random()
        )
        try await sleeper(delay)
        try Task.checkCancellation()
        let previousURL = current.url
        let previousSubprotocol = current.negotiatedSubprotocol
        let connection = try await client.connect(request)
        if let restorerWithContext {
            try await restorerWithContext(
                connection,
                WebSocketReconnectContext(
                    attempt: attempt,
                    previousURL: previousURL,
                    previousSubprotocol: previousSubprotocol
                )
            )
        } else if let restorer {
            try await restorer(connection)
        }
        current = connection
        broadcaster.emit(.open)
    }

    private func shouldReconnect(after error: any Error) -> Bool {
        guard let webSocketError = error as? WebSocketError else {
            return error is URLError
        }
        switch webSocketError {
        case .connectionClosed, .transport, .handshakeFailed, .unknown:
            return true
        default:
            return false
        }
    }

    private func closeAfterFailure(_ error: any Error) async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        // Release the underlying task when the bounded policy is exhausted.
        // The wrapper's state stream is terminal even if the base connection
        // has already reported a close, and closing is idempotent for the
        // Foundation and mock implementations.
        try? await current.close(code: .goingAway, reason: "Reconnect policy exhausted")
        let close: WebSocketClose?
        if let webSocketError = error as? WebSocketError,
           case .connectionClosed(let value) = webSocketError {
            close = value
        } else {
            close = nil
        }
        broadcaster.finish(.closed(close))
    }
}
