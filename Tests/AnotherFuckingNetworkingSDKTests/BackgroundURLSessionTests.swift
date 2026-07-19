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

    @Test("Background identity round-trips through durable JSON")
    func backgroundIdentityRoundTrips() throws {
        let jobID = UUID()
        let descriptor = BackgroundTransferTaskDescriptor(
            taskIdentifier: 42,
            jobID: jobID,
            originalURL: URL(string: "https://example.com/export")!,
            isDownload: true
        )
        let route = BackgroundTransferRoute(
            taskIdentifier: descriptor.taskIdentifier,
            jobID: jobID,
            kind: .download
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        #expect(try decoder.decode(
            BackgroundTransferTaskDescriptor.self,
            from: encoder.encode(descriptor)
        ) == descriptor)
        #expect(try decoder.decode(
            BackgroundTransferRoute.self,
            from: encoder.encode(route)
        ) == route)
    }

    @Test("Background events route through actor-isolated durable bindings")
    func eventRouterRoutesAndReconciles() async throws {
        let jobID = UUID()
        let route = BackgroundTransferRoute(
            taskIdentifier: 42,
            jobID: jobID,
            kind: .download
        )
        let router = BackgroundTransferEventRouter()
        try await router.bind(route)

        let progress = BackgroundTransferEvent.downloadProgress(
            taskIdentifier: 42,
            bytesWritten: 8,
            totalBytes: 16
        )
        let routed = await router.handle(progress)
        #expect(routed?.route == route)
        #expect(routed?.event == progress)
        #expect((await router.snapshot()) == [route])

        try await router.reconcile(route)
        await router.unbind(taskIdentifier: 42)
        #expect(await router.handle(progress) == nil)
        #expect(await router.handle(.backgroundEventsFinished)?.route == nil)
    }

    @Test("Background event router rejects task ID collisions")
    func eventRouterRejectsCollisions() async throws {
        let router = BackgroundTransferEventRouter()
        try await router.bind(BackgroundTransferRoute(
            taskIdentifier: 7,
            jobID: UUID(),
            kind: .upload
        ))

        await #expect(throws: BackgroundTransferRouterError.taskAlreadyBound(7)) {
            try await router.bind(BackgroundTransferRoute(
                taskIdentifier: 7,
                jobID: UUID(),
                kind: .download
            ))
        }
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

    @Test("Resume-data validation supports bounded and strict modes")
    func resumeDataValidation() throws {
        let validator = try BackgroundTransferResumeDataValidator(
            maximumBytes: 128
        )
        #expect(try validator.validate(nil) == nil)
        #expect(try validator.validate(Data([1, 2, 3])) == Data([1, 2, 3]))

        let propertyList = try PropertyListSerialization.data(
            fromPropertyList: ["resume": "token"],
            format: .binary,
            options: 0
        )
        #expect(try validator.validate(
            propertyList,
            mode: .propertyList
        ) == propertyList)

        do {
            _ = try validator.validate(Data(), mode: .bounded)
            Issue.record("Expected empty resume data to fail")
        } catch let error as BackgroundTransferResumeDataValidationError {
            #expect(error == .empty)
        }

        do {
            _ = try validator.validate(
                Data(repeating: 0, count: 129),
                mode: .bounded
            )
            Issue.record("Expected oversized resume data to fail")
        } catch let error as BackgroundTransferResumeDataValidationError {
            #expect(error == .tooLarge(maximumBytes: 128, actualBytes: 129))
        }

        do {
            _ = try validator.validate(
                Data([0, 1, 2]),
                mode: .propertyList
            )
            Issue.record("Expected malformed property list to fail")
        } catch let error as BackgroundTransferResumeDataValidationError {
            #expect(error == .malformedPropertyList)
        }
    }

    @Test("Validated downloads reject malformed resume data before task creation")
    func validatedDownloadRejectsMalformedData() throws {
        let adapter = BackgroundURLSessionAdapter(
            identifier: "com.anotherfuckingnetworkingsdk.validation.\(UUID())"
        ) { _ in }
        defer { adapter.invalidateAndCancel() }

        let request = URLRequest(
            url: URL(string: "https://example.com/large-file")!
        )
        do {
            _ = try adapter.downloadValidated(
                request,
                resumeData: Data([0, 1, 2]),
                mode: .propertyList
            )
            Issue.record("Expected malformed resume data to be rejected")
        } catch let error as BackgroundTransferResumeDataValidationError {
            #expect(error == .malformedPropertyList)
        }

        let task = try adapter.downloadValidated(request)
        task.cancel()
    }

    @Test("Background task controls report missing relaunch tasks")
    func missingTaskControls() async throws {
        let adapter = BackgroundURLSessionAdapter(
            identifier: "com.anotherfuckingnetworkingsdk.controls.\(UUID())"
        ) { _ in }
        defer { adapter.invalidateAndCancel() }

        await #expect(throws:
            BackgroundTransferTaskControlError.taskNotFound(999)
        ) {
            try await adapter.pauseDownload(taskIdentifier: 999)
        }
        await #expect(throws:
            BackgroundTransferTaskControlError.taskNotFound(999)
        ) {
            try await adapter.cancel(taskIdentifier: 999)
        }
        await #expect(throws:
            BackgroundTransferTaskControlError.taskNotFound(999)
        ) {
            try await adapter.resume(taskIdentifier: 999)
        }
    }
}
