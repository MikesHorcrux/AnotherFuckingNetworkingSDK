#if canImport(Network)
import Foundation
import Network

/// The coarse connectivity state reported by NetworkPathMonitor.
public enum NetworkPathStatus: String, Equatable, Sendable {
    case unknown
    case satisfied
    case unsatisfied
    case requiresConnection
}

/// Interface categories exposed without leaking NWInterface values across the
/// concurrency boundary.
public enum NetworkPathInterface: String, CaseIterable, Hashable, Sendable {
    case wifi
    case wiredEthernet
    case cellular
    case loopback
    case other
}

/// A privacy-safe snapshot of path conditions.
public struct NetworkPathSnapshot: Equatable, Sendable {
    public let status: NetworkPathStatus
    public let isExpensive: Bool
    public let isConstrained: Bool
    public let supportsDNS: Bool
    public let supportsIPv4: Bool
    public let supportsIPv6: Bool
    public let interfaces: Set<NetworkPathInterface>

    public init(
        status: NetworkPathStatus = .unknown,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        supportsDNS: Bool = false,
        supportsIPv4: Bool = false,
        supportsIPv6: Bool = false,
        interfaces: Set<NetworkPathInterface> = []
    ) {
        self.status = status
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsDNS = supportsDNS
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.interfaces = interfaces
    }

    fileprivate init(_ path: NWPath) {
        let status: NetworkPathStatus
        switch path.status {
        case .satisfied:
            status = .satisfied
        case .unsatisfied:
            status = .unsatisfied
        case .requiresConnection:
            status = .requiresConnection
        @unknown default:
            status = .unknown
        }

        var interfaces = Set<NetworkPathInterface>()
        for interface in path.availableInterfaces {
            switch interface.type {
            case .wifi:
                interfaces.insert(.wifi)
            case .wiredEthernet:
                interfaces.insert(.wiredEthernet)
            case .cellular:
                interfaces.insert(.cellular)
            case .loopback:
                interfaces.insert(.loopback)
            case .other:
                interfaces.insert(.other)
            @unknown default:
                interfaces.insert(.other)
            }
        }

        self.init(
            status: status,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            supportsDNS: path.supportsDNS,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            interfaces: interfaces
        )
    }
}

/// An opt-in, newest-only connectivity path observer.
///
/// This observer never blocks or retries requests. Use its snapshots to
/// choose policy, display diagnostics, or annotate telemetry; let URLSession
/// remain responsible for transport connectivity and waitsForConnectivity.
public final class NetworkPathMonitor: @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let state = CriticalState(NetworkPathSnapshot())
    private let broadcaster = LatestValueBroadcaster(NetworkPathSnapshot())
    private let lifecycle = CriticalState(Lifecycle())

    private struct Lifecycle: Sendable {
        var started = false
        var cancelled = false
    }

    public init(
        requiredInterface: NetworkPathInterface? = nil,
        queueLabel: String = "AnotherFuckingNetworkingSDK.network-path"
    ) {
        if let requiredInterface {
            monitor = NWPathMonitor(
                requiredInterfaceType: requiredInterface.nwInterfaceType
            )
        } else {
            monitor = NWPathMonitor()
        }
        queue = DispatchQueue(
            label: queueLabel.isEmpty
                ? "AnotherFuckingNetworkingSDK.network-path"
                : queueLabel
        )
    }

    deinit {
        cancel()
    }

    /// The most recent snapshot, or unknown before the first callback.
    public var currentSnapshot: NetworkPathSnapshot {
        state.withCriticalRegion { $0 }
    }

    /// A bounded newest-only stream that immediately yields the current value.
    public var snapshots: AsyncStream<NetworkPathSnapshot> {
        broadcaster.stream()
    }

    /// Starts observation once. Calling this repeatedly is harmless.
    public func start() {
        let shouldStart = lifecycle.withCriticalRegion { lifecycle in
            guard !lifecycle.started, !lifecycle.cancelled else { return false }
            lifecycle.started = true
            return true
        }
        guard shouldStart else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            self?.publish(NetworkPathSnapshot(path))
        }
        monitor.start(queue: queue)
    }

    /// Stops observation and finishes existing snapshot streams.
    public func cancel() {
        let shouldCancel = lifecycle.withCriticalRegion { lifecycle in
            guard !lifecycle.cancelled else { return false }
            lifecycle.cancelled = true
            return true
        }
        guard shouldCancel else { return }
        monitor.cancel()
        broadcaster.finish(with: currentSnapshot)
    }

    private func publish(_ snapshot: NetworkPathSnapshot) {
        let shouldPublish = lifecycle.withCriticalRegion { lifecycle in
            lifecycle.started && !lifecycle.cancelled
        }
        guard shouldPublish else { return }
        state.withCriticalRegion { $0 = snapshot }
        broadcaster.publish(snapshot)
    }
}

private extension NetworkPathInterface {
    var nwInterfaceType: NWInterface.InterfaceType {
        switch self {
        case .wifi:
            return .wifi
        case .wiredEthernet:
            return .wiredEthernet
        case .cellular:
            return .cellular
        case .loopback:
            return .loopback
        case .other:
            return .other
        }
    }
}
#endif
