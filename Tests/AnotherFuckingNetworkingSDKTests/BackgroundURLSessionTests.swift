import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("Background URLSession adapter")
struct BackgroundURLSessionTests {
    @Test("Background metrics events retain only the stable snapshot")
    func metricsEventIsSendableAndEquatable() {
        let snapshot = NetworkTaskMetricsSnapshot(
            fetchStart: Date(timeIntervalSince1970: 1),
            responseEnd: Date(timeIntervalSince1970: 2),
            requestDurationNanoseconds: 1_000
        )
        let event = BackgroundTransferEvent.metrics(
            taskIdentifier: 7,
            snapshot: snapshot
        )

        #expect(event == .metrics(taskIdentifier: 7, snapshot: snapshot))
    }

    @Test("Background completion is delivered after the terminal event")
    func backgroundCompletionOrdering() {
        let events = LockedBox<[BackgroundTransferEvent]>([])
        let completionCount = LockedBox(0)
        let delegate = BackgroundURLSessionDelegate { event in
            events.withLock { $0.append(event) }
        }
        delegate.setBackgroundEventsCompletionHandler {
            completionCount.withLock { $0 += 1 }
        }

        let session = URLSession(configuration: .ephemeral)
        delegate.urlSessionDidFinishEvents(forBackgroundURLSession: session)

        #expect(events.withLock { $0 } == [.backgroundEventsFinished])
        #expect(completionCount.withLock { $0 } == 1)
    }

    @Test("Completion handlers are one-shot")
    func completionHandlerIsOneShot() {
        let completionCount = LockedBox(0)
        let delegate = BackgroundURLSessionDelegate { _ in }
        delegate.setBackgroundEventsCompletionHandler {
            completionCount.withLock { $0 += 1 }
        }
        let session = URLSession(configuration: .ephemeral)

        delegate.urlSessionDidFinishEvents(forBackgroundURLSession: session)
        delegate.urlSessionDidFinishEvents(forBackgroundURLSession: session)

        #expect(completionCount.withLock { $0 } == 1)
    }
}
