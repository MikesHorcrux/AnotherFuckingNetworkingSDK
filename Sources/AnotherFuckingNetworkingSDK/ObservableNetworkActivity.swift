import Observation

/// Main-actor presentation state for an opt-in network activity monitor.
///
/// The networking client and monitor remain off the main actor. This adapter
/// performs only small property assignments there, giving Observation clients
/// fine-grained invalidation without moving encoding, transport, or decoding
/// work onto the UI executor.
@available(iOS 17.0, macOS 14.0, *)
@MainActor
@Observable
public final class ObservableNetworkActivity {
    public private(set) var revision: UInt64
    public private(set) var activeRequestCount: Int
    public private(set) var activeUploadCount: Int
    public private(set) var activeDownloadCount: Int
    public private(set) var activeWebSocketHandshakeCount: Int
    public private(set) var succeededCount: UInt64
    public private(set) var failedCount: UInt64
    public private(set) var cancelledCount: UInt64

    @ObservationIgnored
    private var observationTask: Task<Void, Never>?

    public init(monitor: NetworkActivityMonitor) {
        let snapshot = monitor.currentSnapshot
        revision = snapshot.revision
        activeRequestCount = snapshot.activeCount(for: .request)
        activeUploadCount = snapshot.activeCount(for: .upload)
        activeDownloadCount = snapshot.activeCount(for: .download)
        activeWebSocketHandshakeCount = snapshot.activeCount(
            for: .webSocketHandshake
        )
        succeededCount = snapshot.succeededCount
        failedCount = snapshot.failedCount
        cancelledCount = snapshot.cancelledCount

        observationTask = Task { [weak self, monitor] in
            for await snapshot in monitor.snapshots() {
                guard !Task.isCancelled, let self else { return }
                apply(snapshot)
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    /// Stops receiving snapshots. The latest values remain readable.
    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    public var totalActiveCount: Int {
        activeRequestCount
            + activeUploadCount
            + activeDownloadCount
            + activeWebSocketHandshakeCount
    }

    private func apply(_ snapshot: NetworkActivitySnapshot) {
        revision = snapshot.revision
        activeRequestCount = snapshot.activeCount(for: .request)
        activeUploadCount = snapshot.activeCount(for: .upload)
        activeDownloadCount = snapshot.activeCount(for: .download)
        activeWebSocketHandshakeCount = snapshot.activeCount(
            for: .webSocketHandshake
        )
        succeededCount = snapshot.succeededCount
        failedCount = snapshot.failedCount
        cancelledCount = snapshot.cancelledCount
    }
}
