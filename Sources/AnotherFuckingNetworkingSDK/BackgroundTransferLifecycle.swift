#if !os(tvOS) && !os(watchOS) && !os(visionOS)
import Foundation

/// The result of applying one routed background transfer event.
public enum BackgroundTransferLifecycleOutcome: Equatable, Sendable {
    case checkpointed(TransferJob)
    case downloadStaged(
        route: BackgroundTransferRoute,
        temporaryURL: URL
    )
    case paused(TransferJob)
    case committed(TransferJob)
    case failed(TransferJob)
    case metrics(
        route: BackgroundTransferRoute,
        snapshot: NetworkTaskMetricsSnapshot
    )
    case backgroundEventsFinished
}

/// Errors raised when a background event cannot be applied to a durable job.
public enum BackgroundTransferLifecycleError: LocalizedError, Equatable, Sendable {
    case jobKindMismatch(UUID)
    case missingTemporaryDownload(UUID)
    case missingDownloadDestination(UUID)

    public var errorDescription: String? {
        switch self {
        case .jobKindMismatch(let id):
            return "Background route kind does not match transfer job \(id.uuidString)."
        case .missingTemporaryDownload(let id):
            return "Background download \(id.uuidString) completed without a temporary file."
        case .missingDownloadDestination(let id):
            return "Background download \(id.uuidString) has no durable destination."
        }
    }
}

/// Applies routed Foundation callbacks to one durable transfer coordinator.
///
/// The actor owns callback ordering, starts jobs restored in a queued or
/// paused state, persists monotonic progress, and commits terminal success only
/// after the caller's download policy has moved the temporary file. Request
/// construction, authentication, and file ownership remain application policy.
public actor BackgroundTransferLifecycleCoordinator {
    public typealias DownloadCommitter = @Sendable (
        BackgroundTransferRoute,
        URL,
        URL?
    ) async throws -> URL

    public typealias MetricsHandler = @Sendable (
        BackgroundTransferRoute,
        NetworkTaskMetricsSnapshot
    ) async -> Void

    private let router: BackgroundTransferEventRouter
    private let coordinator: TransferJobCoordinator
    private let commitDownload: DownloadCommitter
    private let metricsHandler: MetricsHandler?
    private var temporaryDownloads: [Int: URL] = [:]

    public init(
        router: BackgroundTransferEventRouter,
        coordinator: TransferJobCoordinator,
        commitDownload: @escaping DownloadCommitter,
        metricsHandler: MetricsHandler? = nil
    ) {
        self.router = router
        self.coordinator = coordinator
        self.commitDownload = commitDownload
        self.metricsHandler = metricsHandler
    }

    /// Routes and applies one delegate event. Unknown task identifiers are
    /// ignored so stale callbacks from a replaced session cannot mutate jobs.
    @discardableResult
    public func handle(
        _ event: BackgroundTransferEvent
    ) async throws -> BackgroundTransferLifecycleOutcome? {
        guard let routed = await router.handle(event) else { return nil }
        guard let route = routed.route else {
            return .backgroundEventsFinished
        }

        switch event {
        case .uploadProgress(_, let bytesSent, let totalBytes):
            return .checkpointed(try await checkpoint(
                route: route,
                bytesCompleted: bytesSent,
                totalBytes: totalBytes,
                operation: .upload
            ))
        case .downloadProgress(_, let bytesWritten, let totalBytes):
            return .checkpointed(try await checkpoint(
                route: route,
                bytesCompleted: bytesWritten,
                totalBytes: totalBytes,
                operation: .download
            ))
        case .downloadFinished(_, let temporaryURL):
            let job = try await requiredJob(for: route)
            guard job.kind == .download, route.kind == .download else {
                throw BackgroundTransferLifecycleError.jobKindMismatch(job.id)
            }
            temporaryDownloads[route.taskIdentifier] = temporaryURL
            return .downloadStaged(route: route, temporaryURL: temporaryURL)
        case .completed(_, let errorDescription, _):
            if let errorDescription {
                let job = try await requiredJob(for: route)
                if let resumeData = eventResumeData(event), !resumeData.isEmpty {
                    let paused = try await coordinator.pause(
                        id: job.id,
                        resumeData: resumeData
                    )
                    temporaryDownloads.removeValue(
                        forKey: route.taskIdentifier
                    )
                    return .paused(paused)
                }
                let failed = try await coordinator.recordFailure(
                    id: job.id,
                    failure: Self.failureIdentity(from: errorDescription)
                )
                temporaryDownloads.removeValue(
                    forKey: route.taskIdentifier
                )
                return .failed(failed)
            }

            let job = try await startJob(for: route)
            let destinationURL: URL?
            if route.kind == .download {
                guard let temporaryURL = temporaryDownloads[
                    route.taskIdentifier
                ] else {
                    throw BackgroundTransferLifecycleError.missingTemporaryDownload(
                        job.id
                    )
                }
                destinationURL = try await commitDownload(
                    route,
                    temporaryURL,
                    job.destinationURL
                )
                temporaryDownloads.removeValue(forKey: route.taskIdentifier)
            } else {
                destinationURL = nil
            }

            return .committed(try await coordinator.commitSuccess(
                id: job.id,
                result: TransferJobResult(
                    bytesCompleted: job.bytesCompleted,
                    totalBytes: job.totalBytes,
                    destinationURL: destinationURL
                )
            ))
        case .metrics(_, let snapshot):
            await metricsHandler?(route, snapshot)
            return .metrics(route: route, snapshot: snapshot)
        case .backgroundEventsFinished:
            return .backgroundEventsFinished
        }
    }

    private func requiredJob(
        for route: BackgroundTransferRoute
    ) async throws -> TransferJob {
        guard let job = await coordinator.job(id: route.jobID) else {
            throw TransferJobCoordinatorError.jobUnavailable(route.jobID)
        }
        guard job.kind == route.kind else {
            throw BackgroundTransferLifecycleError.jobKindMismatch(job.id)
        }
        return job
    }

    private func startJob(
        for route: BackgroundTransferRoute
    ) async throws -> TransferJob {
        _ = try await requiredJob(for: route)
        return try await coordinator.start(id: route.jobID)
    }

    private func checkpoint(
        route: BackgroundTransferRoute,
        bytesCompleted: Int64,
        totalBytes: Int64,
        operation: TransferProgressOperation
    ) async throws -> TransferJob {
        let job = try await startJob(for: route)
        return try await coordinator.recordCheckpoint(
            id: job.id,
            update: TransferJobUpdate(
                progress: TransferProgress(
                    operation: operation,
                    phase: .running,
                    bytesCompleted: bytesCompleted,
                    totalBytes: totalBytes,
                    attempt: job.attempt
                )
            )
        )
    }

    private func eventResumeData(
        _ event: BackgroundTransferEvent
    ) -> Data? {
        guard case .completed(_, _, let resumeData) = event else {
            return nil
        }
        return resumeData
    }

    private static func failureIdentity(
        from description: String
    ) -> TransferJobFailure {
        guard let marker = description.range(
            of: " (",
            options: .backwards
        ),
              description.last == ")",
              let code = Int(description[
                description.index(marker.lowerBound, offsetBy: 2)
                ..< description.index(before: description.endIndex)
            ]) else {
            return TransferJobFailure(
                domain: "com.anotherfuckingnetworkingsdk.background",
                code: -1
            )
        }
        return TransferJobFailure(
            domain: String(description[..<marker.lowerBound]),
            code: code
        )
    }
}

public extension BackgroundTransferLifecycleCoordinator {
    /// Reconciles task descriptors discovered after process relaunch.
    ///
    /// The method validates every descriptor against the restored durable job
    /// index before binding it. Unknown or identity-less tasks are reported as
    /// orphans for application cleanup; direction mismatches are reported
    /// separately and never reach the event router. Existing identical routes
    /// are reconciled idempotently, while task-ID collisions still throw.
    @discardableResult
    func reconcile(
        _ descriptors: [BackgroundTransferTaskDescriptor]
    ) async throws -> BackgroundTransferRelaunchReport {
        var routes: [BackgroundTransferRoute] = []
        var orphaned: [Int] = []
        var mismatched: [Int] = []

        for descriptor in descriptors {
            guard let jobID = descriptor.jobID,
                  let job = await coordinator.job(id: jobID) else {
                orphaned.append(descriptor.taskIdentifier)
                continue
            }

            let jobIsDownload = job.kind == .download
            guard descriptor.isDownload == jobIsDownload else {
                mismatched.append(descriptor.taskIdentifier)
                continue
            }

            let route = BackgroundTransferRoute(
                taskIdentifier: descriptor.taskIdentifier,
                jobID: job.id,
                kind: job.kind
            )
            try await router.reconcile(route)
            routes.append(route)
        }

        return BackgroundTransferRelaunchReport(
            routes: routes,
            orphanedTaskIdentifiers: orphaned,
            mismatchedTaskIdentifiers: mismatched
        )
    }

    /// Enumerates and reconciles the adapter's live tasks in one operation.
    @discardableResult
    func reconcile(
        adapter: BackgroundURLSessionAdapter
    ) async throws -> BackgroundTransferRelaunchReport {
        try await reconcile(await adapter.transferTasks())
    }
}
#endif
