import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("Task metrics snapshots")
struct TaskMetricsSnapshotTests {
    @Test("Snapshots preserve stable timing values")
    func preservesValues() {
        let snapshot = NetworkTaskMetricsSnapshot(
            fetchStart: Date(timeIntervalSince1970: 1),
            responseStart: Date(timeIntervalSince1970: 2),
            responseEnd: Date(timeIntervalSince1970: 3),
            domainLookupDurationNanoseconds: UInt64.max,
            secureConnectionDurationNanoseconds: nil,
            requestDurationNanoseconds: 10
        )

        #expect(snapshot.fetchStart == Date(timeIntervalSince1970: 1))
        #expect(snapshot.responseEnd == Date(timeIntervalSince1970: 3))
        #expect(snapshot.domainLookupDurationNanoseconds == UInt64.max)
        #expect(snapshot.secureConnectionDurationNanoseconds == nil)
        #expect(snapshot.requestDurationNanoseconds == 10)
    }
}
