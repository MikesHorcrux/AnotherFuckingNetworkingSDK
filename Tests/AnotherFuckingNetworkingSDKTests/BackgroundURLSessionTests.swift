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
        #expect(event.taskIdentifier == 7)
        #expect(!event.isTerminal)
        #expect(BackgroundTransferEvent.backgroundEventsFinished.taskIdentifier == nil)
        #expect(BackgroundTransferEvent.backgroundEventsFinished.isTerminal)
    }

    @Test("Background task descriptors preserve relaunch identity")
    func taskDescriptorPreservesIdentity() {
        let jobID = UUID()
        let descriptor = BackgroundTransferTaskDescriptor(
            taskIdentifier: 42,
            jobID: jobID,
            originalURL: URL(string: "https://example.com/export")!,
            isDownload: true
        )

        #expect(descriptor.taskIdentifier == 42)
        #expect(descriptor.jobID == jobID)
        #expect(descriptor.isDownload)
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

    @Test("Background delegate drops oversized resume data")
    func oversizedResumeDataIsDropped() {
        let events = LockedBox<[BackgroundTransferEvent]>([])
        let delegate = BackgroundURLSessionDelegate { event in
            events.withLock { $0.append(event) }
        }
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(
            with: URL(string: "https://example.com/file")!
        )
        let error = NSError(
            domain: "com.example.transfer",
            code: 1,
            userInfo: [
                NSURLSessionDownloadTaskResumeData:
                    Data(repeating: 0, count: 8 * 1_024 * 1_024 + 1)
            ]
        )

        delegate.urlSession(session, task: task, didCompleteWithError: error)

        guard case .completed(_, let errorDescription, let resumeData)? =
            events.withLock({ $0.first }) else {
            Issue.record("Expected a completion event")
            return
        }
        #expect(errorDescription == "com.example.transfer (1)")
        #expect(resumeData == nil)
    }
}
