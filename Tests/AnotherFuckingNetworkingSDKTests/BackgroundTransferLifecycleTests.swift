import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("Background transfer lifecycle")
struct BackgroundTransferLifecycleTests {
    @Test("Progress callbacks start queued jobs and persist checkpoints")
    func progressStartsAndCheckpoints() async throws {
        let store = InMemoryTransferJobStore()
        let coordinator = TransferJobCoordinator(store: store)
        let job = TransferJob(
            kind: .upload,
            requestKey: "archive",
            totalBytes: nil
        )
        try await coordinator.enqueue(job)

        let route = BackgroundTransferRoute(
            taskIdentifier: 4,
            jobID: job.id,
            kind: .upload
        )
        let router = BackgroundTransferEventRouter(routes: [route])
        let lifecycle = BackgroundTransferLifecycleCoordinator(
            router: router,
            coordinator: coordinator,
            commitDownload: { _, temporaryURL, _ in temporaryURL }
        )

        let outcome = try await lifecycle.handle(.uploadProgress(
            taskIdentifier: 4,
            bytesSent: 7,
            totalBytes: 12
        ))

        guard case .checkpointed(let checkpointed)? = outcome else {
            Issue.record("Expected a persisted checkpoint")
            return
        }
        #expect(checkpointed.state == .running)
        #expect(checkpointed.bytesCompleted == 7)
        #expect(checkpointed.totalBytes == 12)
        #expect(checkpointed.attempt == 1)
    }

    @Test("Download completion commits the temporary file before success")
    func downloadCommitOrdering() async throws {
        let store = InMemoryTransferJobStore()
        let coordinator = TransferJobCoordinator(store: store)
        let destination = URL(fileURLWithPath: "/tmp/export.bin")
        let job = TransferJob(
            kind: .download,
            requestKey: "export",
            destinationURL: destination
        )
        try await coordinator.enqueue(job)

        let route = BackgroundTransferRoute(
            taskIdentifier: 9,
            jobID: job.id,
            kind: .download
        )
        let router = BackgroundTransferEventRouter(routes: [route])
        let committedURLs = LockedBox<[URL]>([])
        let lifecycle = BackgroundTransferLifecycleCoordinator(
            router: router,
            coordinator: coordinator,
            commitDownload: { _, temporaryURL, expectedDestination in
                committedURLs.withLock { $0.append(temporaryURL) }
                #expect(expectedDestination == destination)
                return destination
            }
        )
        let temporary = URL(fileURLWithPath: "/tmp/temporary-export.bin")

        _ = try await lifecycle.handle(.downloadProgress(
            taskIdentifier: 9,
            bytesWritten: 12,
            totalBytes: 20
        ))
        _ = try await lifecycle.handle(.downloadFinished(
            taskIdentifier: 9,
            temporaryURL: temporary
        ))
        let outcome = try await lifecycle.handle(.completed(
            taskIdentifier: 9,
            errorDescription: nil,
            resumeData: nil
        ))

        guard case .committed(let finished)? = outcome else {
            Issue.record("Expected a committed transfer")
            return
        }
        #expect(committedURLs.withLock { $0 } == [temporary])
        #expect(finished.state == .succeeded)
        #expect(finished.bytesCompleted == 12)
        #expect(finished.destinationURL == destination)
    }

    @Test("A failed destination commit does not terminate the durable job")
    func failedDestinationCommitIsRetryable() async throws {
        let store = InMemoryTransferJobStore()
        let coordinator = TransferJobCoordinator(store: store)
        let job = TransferJob(kind: .download, requestKey: "retryable")
        try await coordinator.enqueue(job)
        let route = BackgroundTransferRoute(
            taskIdentifier: 10,
            jobID: job.id,
            kind: .download
        )
        let shouldFail = CriticalState(true)
        let lifecycle = BackgroundTransferLifecycleCoordinator(
            router: BackgroundTransferEventRouter(routes: [route]),
            coordinator: coordinator,
            commitDownload: { _, temporaryURL, _ in
                let fail = shouldFail.withCriticalRegion { value in
                    defer { value = false }
                    return value
                }
                if fail {
                    throw NSError(domain: "file", code: 1)
                }
                return temporaryURL
            }
        )
        let temporary = URL(fileURLWithPath: "/tmp/retryable.bin")
        _ = try await lifecycle.handle(.downloadFinished(
            taskIdentifier: 10,
            temporaryURL: temporary
        ))

        do {
            _ = try await lifecycle.handle(.completed(
                taskIdentifier: 10,
                errorDescription: nil,
                resumeData: nil
            ))
            Issue.record("Expected destination commit to fail")
        } catch let error as NSError {
            #expect(error.domain == "file")
            #expect(error.code == 1)
        }
        #expect(await coordinator.job(id: job.id)?.state == .running)

        let outcome = try await lifecycle.handle(.completed(
            taskIdentifier: 10,
            errorDescription: nil,
            resumeData: nil
        ))
        guard case .committed(let finished)? = outcome else {
            Issue.record("Expected the retained temporary file to be retryable")
            return
        }
        #expect(finished.state == .succeeded)
    }

    @Test("Resumable background completion pauses and preserves resume data")
    func resumableCompletionPauses() async throws {
        let store = InMemoryTransferJobStore()
        let coordinator = TransferJobCoordinator(store: store)
        let job = TransferJob(kind: .download, requestKey: "resume")
        try await coordinator.enqueue(job)
        let route = BackgroundTransferRoute(
            taskIdentifier: 11,
            jobID: job.id,
            kind: .download
        )
        let lifecycle = BackgroundTransferLifecycleCoordinator(
            router: BackgroundTransferEventRouter(routes: [route]),
            coordinator: coordinator,
            commitDownload: { _, temporaryURL, _ in temporaryURL }
        )
        let resumeData = Data([4, 5, 6])

        let outcome = try await lifecycle.handle(.completed(
            taskIdentifier: 11,
            errorDescription: "NSURLErrorDomain (-999)",
            resumeData: resumeData
        ))

        guard case .paused(let paused)? = outcome else {
            Issue.record("Expected resumable completion to pause the job")
            return
        }
        #expect(paused.state == .paused)
        #expect(paused.resumeData == resumeData)
        #expect(paused.lastError == nil)
    }

    @Test("Malformed callback failures become a safe bounded identity")
    func malformedFailureIsSafe() async throws {
        let store = InMemoryTransferJobStore()
        let coordinator = TransferJobCoordinator(store: store)
        let job = TransferJob(kind: .download, requestKey: "private")
        try await coordinator.enqueue(job)
        let route = BackgroundTransferRoute(
            taskIdentifier: 12,
            jobID: job.id,
            kind: .download
        )
        let lifecycle = BackgroundTransferLifecycleCoordinator(
            router: BackgroundTransferEventRouter(routes: [route]),
            coordinator: coordinator,
            commitDownload: { _, temporaryURL, _ in temporaryURL }
        )

        let outcome = try await lifecycle.handle(.completed(
            taskIdentifier: 12,
            errorDescription: "Authorization: secret response body",
            resumeData: nil
        ))

        guard case .failed(let failed)? = outcome else {
            Issue.record("Expected a failed transfer")
            return
        }
        #expect(failed.state == .failed)
        #expect(failed.lastError ==
            "com.anotherfuckingnetworkingsdk.background (-1)")
        #expect(failed.lastError?.contains("secret") == false)
    }

    @Test("Metrics and session completion remain observable")
    func metricsAndCompletion() async throws {
        let store = InMemoryTransferJobStore()
        let coordinator = TransferJobCoordinator(store: store)
        let job = TransferJob(kind: .upload, requestKey: "metrics")
        try await coordinator.enqueue(job)
        let route = BackgroundTransferRoute(
            taskIdentifier: 15,
            jobID: job.id,
            kind: .upload
        )
        let snapshots = LockedBox<[NetworkTaskMetricsSnapshot]>([])
        let lifecycle = BackgroundTransferLifecycleCoordinator(
            router: BackgroundTransferEventRouter(routes: [route]),
            coordinator: coordinator,
            commitDownload: { _, temporaryURL, _ in temporaryURL },
            metricsHandler: { _, snapshot in
                snapshots.withLock { $0.append(snapshot) }
            }
        )
        let snapshot = NetworkTaskMetricsSnapshot(
            requestDurationNanoseconds: 4
        )

        #expect(try await lifecycle.handle(.metrics(
            taskIdentifier: 15,
            snapshot: snapshot
        )) == .metrics(route: route, snapshot: snapshot))
        #expect(try await lifecycle.handle(.backgroundEventsFinished) ==
            .backgroundEventsFinished)
        #expect(snapshots.withLock { $0 } == [snapshot])
    }
}
