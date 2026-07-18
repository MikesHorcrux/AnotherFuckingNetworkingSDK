#if !os(tvOS) && !os(watchOS) && !os(visionOS)
import Foundation

/// The result of reconciling Foundation's post-relaunch task inventory.
public struct BackgroundTransferRelaunchReport: Equatable, Sendable {
    /// Routes that were validated and rebound to the actor-isolated router.
    public let routes: [BackgroundTransferRoute]
    /// Task identifiers that have no durable job identity or no matching job.
    public let orphanedTaskIdentifiers: [Int]
    /// Task identifiers whose Foundation direction disagrees with the job.
    public let mismatchedTaskIdentifiers: [Int]
    /// Non-terminal durable jobs that have no valid Foundation task route.
    public let jobsWithoutTasks: [UUID]

    public init(
        routes: [BackgroundTransferRoute] = [],
        orphanedTaskIdentifiers: [Int] = [],
        mismatchedTaskIdentifiers: [Int] = [],
        jobsWithoutTasks: [UUID] = []
    ) {
        self.routes = routes.sorted { $0.taskIdentifier < $1.taskIdentifier }
        self.orphanedTaskIdentifiers = Array(
            Set(orphanedTaskIdentifiers)
        ).sorted()
        self.mismatchedTaskIdentifiers = Array(
            Set(mismatchedTaskIdentifiers)
        ).sorted()
        self.jobsWithoutTasks = Array(Set(jobsWithoutTasks)).sorted {
            $0.uuidString < $1.uuidString
        }
    }
}

#endif
