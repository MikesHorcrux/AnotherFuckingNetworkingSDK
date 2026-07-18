#if !os(tvOS) && !os(watchOS) && !os(visionOS)
import Foundation

/// Associates a Foundation background task with one durable transfer job.
///
/// Task identifiers are only meaningful within their URLSession. Persist the
/// durable job separately and rebuild these routes from
/// ``BackgroundTransferTaskDescriptor`` values after relaunch.
public struct BackgroundTransferRoute: Equatable, Sendable {
    public let taskIdentifier: Int
    public let jobID: UUID
    public let kind: TransferJobKind

    public init(
        taskIdentifier: Int,
        jobID: UUID,
        kind: TransferJobKind
    ) {
        self.taskIdentifier = taskIdentifier
        self.jobID = jobID
        self.kind = kind
    }
}

/// A background event paired with its durable job route.
public struct BackgroundTransferRoutedEvent: Sendable {
    /// `nil` is used only for the session-wide
    /// ``BackgroundTransferEvent/backgroundEventsFinished`` event.
    public let route: BackgroundTransferRoute?
    public let event: BackgroundTransferEvent

    public init(
        route: BackgroundTransferRoute?,
        event: BackgroundTransferEvent
    ) {
        self.route = route
        self.event = event
    }
}

/// Errors raised when task-to-job routes are inconsistent.
public enum BackgroundTransferRouterError: LocalizedError, Equatable, Sendable {
    case taskAlreadyBound(Int)

    public var errorDescription: String? {
        switch self {
        case .taskAlreadyBound(let taskIdentifier):
            return "Background task \(taskIdentifier) is already bound to a job."
        }
    }
}

/// Actor-isolated routing for background URLSession callbacks.
///
/// The router deliberately does not mutate ``TransferJobCoordinator``. It
/// produces typed routed events so the application can move temporary files,
/// validate resume data, and then commit the corresponding durable state in
/// one policy-aware transaction.
public actor BackgroundTransferEventRouter {
    private var routes: [Int: BackgroundTransferRoute]

    public init(routes: [BackgroundTransferRoute] = []) {
        self.routes = routes.reduce(into: [:]) { result, route in
            // Keep the first binding deterministic; callers that need
            // collision diagnostics should use `bind` or `reconcile`.
            if result[route.taskIdentifier] == nil {
                result[route.taskIdentifier] = route
            }
        }
    }

    /// Binds a task identifier exactly once.
    public func bind(_ route: BackgroundTransferRoute) throws {
        guard routes[route.taskIdentifier] == nil else {
            throw BackgroundTransferRouterError.taskAlreadyBound(
                route.taskIdentifier
            )
        }
        routes[route.taskIdentifier] = route
    }

    /// Replaces a route only when the task is already bound to the same job.
    /// This makes relaunch reconciliation idempotent while rejecting accidental
    /// task-ID reuse across jobs.
    public func reconcile(_ route: BackgroundTransferRoute) throws {
        if let existing = routes[route.taskIdentifier], existing != route {
            throw BackgroundTransferRouterError.taskAlreadyBound(
                route.taskIdentifier
            )
        }
        routes[route.taskIdentifier] = route
    }

    public func unbind(taskIdentifier: Int) {
        routes.removeValue(forKey: taskIdentifier)
    }

    public func route(for taskIdentifier: Int) -> BackgroundTransferRoute? {
        routes[taskIdentifier]
    }

    public func snapshot() -> [BackgroundTransferRoute] {
        routes.values.sorted { $0.taskIdentifier < $1.taskIdentifier }
    }

    /// Resolves a task-scoped event, or returns the session-wide completion
    /// event with a `nil` route. Unknown task identifiers are ignored.
    public func handle(
        _ event: BackgroundTransferEvent
    ) -> BackgroundTransferRoutedEvent? {
        guard let taskIdentifier = event.taskIdentifier else {
            guard case .backgroundEventsFinished = event else { return nil }
            return BackgroundTransferRoutedEvent(route: nil, event: event)
        }
        guard let route = routes[taskIdentifier] else { return nil }
        return BackgroundTransferRoutedEvent(route: route, event: event)
    }
}
#endif
