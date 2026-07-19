import Observation

/// Main-actor Observation state for a WebSocket lifecycle sequence.
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
@MainActor
@Observable
public final class ObservableWebSocketState {
    public private(set) var state: WebSocketConnectionState

    @ObservationIgnored
    private var observationTask: Task<Void, Never>?

    /// Starts observing the connection. A successfully returned SDK
    /// connection is open, so `.open` is the default until the stream's
    /// current snapshot arrives.
    public init(
        connection: any WebSocketConnectionProtocol,
        initialState: WebSocketConnectionState = .open
    ) {
        state = initialState
        observationTask = Task { [weak self, connection] in
            for await state in connection.states {
                guard !Task.isCancelled, let self else { return }
                self.state = state
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    public var isOpen: Bool {
        if case .open = state { return true }
        return false
    }

    public var isClosing: Bool {
        if case .closing = state { return true }
        return false
    }

    public var close: WebSocketClose? {
        if case .closed(let close) = state { return close }
        return nil
    }

    /// Stops receiving lifecycle changes while retaining the latest state.
    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }
}
