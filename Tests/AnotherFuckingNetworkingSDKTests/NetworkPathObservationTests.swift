#if canImport(Network)
import Network
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("Network path observation")
struct NetworkPathObservationTests {
    @Test("Snapshots are privacy-safe, Sendable, and deterministic")
    func snapshotSurface() {
        let snapshot = NetworkPathSnapshot(
            status: .satisfied,
            isExpensive: true,
            isConstrained: true,
            supportsDNS: true,
            supportsIPv4: true,
            supportsIPv6: false,
            interfaces: [.cellular]
        )

        #expect(snapshot.status == .satisfied)
        #expect(snapshot.isExpensive)
        #expect(snapshot.isConstrained)
        #expect(snapshot.supportsDNS)
        #expect(snapshot.supportsIPv4)
        #expect(!snapshot.supportsIPv6)
        #expect(snapshot.interfaces == [.cellular])
    }

    @Test("The monitor starts with unknown state and finishes on cancellation")
    func lifecycle() async {
        let monitor = NetworkPathMonitor(
            requiredInterface: .loopback,
            queueLabel: "AnotherFuckingNetworkingSDK.tests.path"
        )
        #expect(monitor.currentSnapshot.status == .unknown)

        var snapshots = monitor.snapshots.makeAsyncIterator()
        #expect(await snapshots.next()?.status == .unknown)
        monitor.start()
        monitor.start()
        monitor.cancel()
        monitor.cancel()
        #expect(await snapshots.next() != nil)
    }
}
#endif
