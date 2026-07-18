#if canImport(Network)
import Network
import Observation

/// Main-actor presentation state for an opt-in network path monitor.
///
/// The underlying ``NetworkPathMonitor`` remains thread-safe and off the main
/// actor. This adapter only assigns the newest immutable snapshot so
/// Observation clients can render connectivity state without moving path
/// callbacks or transport work onto the UI executor.
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
@MainActor
@Observable
public final class ObservableNetworkPath {
    public private(set) var snapshot: NetworkPathSnapshot

    @ObservationIgnored
    private let monitor: NetworkPathMonitor

    @ObservationIgnored
    private var observationTask: Task<Void, Never>?

    /// Creates an adapter and subscribes to newest-only path snapshots.
    ///
    /// The monitor is not started automatically. Call ``start()`` when the
    /// application is ready to observe connectivity, or start the supplied
    /// monitor independently when its lifecycle is shared elsewhere.
    public init(monitor: NetworkPathMonitor) {
        self.monitor = monitor
        snapshot = monitor.currentSnapshot
        observationTask = Task { [weak self, monitor] in
            for await snapshot in monitor.snapshots {
                guard !Task.isCancelled, let self else { return }
                self.snapshot = snapshot
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    /// Starts the underlying path monitor. Repeated calls are harmless.
    public func start() {
        monitor.start()
    }

    /// Stops receiving snapshots while leaving the latest value readable.
    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }
}
#endif
