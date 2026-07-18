#if canImport(Network)
import Network
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("Observable network path")
struct ObservableNetworkPathTests {
    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    @MainActor
    @Test("The adapter mirrors snapshots without starting transport")
    func mirrorsSnapshots() async {
        let monitor = NetworkPathMonitor(
            requiredInterface: .loopback,
            queueLabel: "AnotherFuckingNetworkingSDK.tests.observable-path"
        )
        let observable = ObservableNetworkPath(monitor: monitor)

        #expect(observable.snapshot.status == .unknown)
        let initial = observable.snapshot
        #expect(observable.snapshot == initial)
        observable.start()
        observable.start()
        await Task.yield()
        observable.stop()
        monitor.cancel()
    }
}
#endif
