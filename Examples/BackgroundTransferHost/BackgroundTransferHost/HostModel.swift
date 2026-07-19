import Foundation
import Observation
import AnotherFuckingNetworkingSDK

@MainActor
@Observable
final class HostModel {
    static let shared = HostModel()

    var sourceURL = "https://speed.hetzner.de/100MB.bin"
    private(set) var status = "Restoring background tasks…"
    private(set) var jobs: [TransferJob] = []
    private(set) var activeTaskIdentifier: Int?

    private let relay: BackgroundEventRelay
    private let store: JSONTransferJobStore
    private let coordinator: TransferJobCoordinator
    private let router: BackgroundTransferEventRouter
    private let lifecycle: BackgroundTransferLifecycleCoordinator
    private let adapter: BackgroundURLSessionAdapter
    private var monitorTask: Task<Void, Never>?

    private init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let directory = applicationSupport.appendingPathComponent(
            "BackgroundTransferHost",
            isDirectory: true
        )
        store = JSONTransferJobStore(
            fileURL: directory.appendingPathComponent("jobs.json")
        )
        coordinator = TransferJobCoordinator(store: store)
        router = BackgroundTransferEventRouter()
        relay = BackgroundEventRelay()

        let lifecycle = BackgroundTransferLifecycleCoordinator(
            router: router,
            coordinator: coordinator,
            commitDownload: Self.commitDownload
        )
        self.lifecycle = lifecycle

        let relay = self.relay
        adapter = BackgroundURLSessionAdapter(
            identifier: "com.anotherfuckingnetworkingsdk.background-host",
            eventHandler: { event in
                Task { await relay.receive(event) }
            }
        )

        monitorTask = Task { [weak self] in
            guard let self else { return }
            await relay.setHandler { event in
                Task {
                    _ = try? await lifecycle.handle(event)
                }
            }
            await self.restoreAndReconcile()
            while !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func startDownload() {
        guard let url = URL(string: sourceURL),
              let scheme = url.scheme?.lowercased(),
              ["https", "http"].contains(scheme) else {
            status = "Enter a valid HTTP(S) URL."
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let id = UUID()
                let destination = try Self.destinationURL(for: id)
                let job = TransferJob(
                    id: id,
                    kind: .download,
                    requestKey: url.absoluteString,
                    destinationURL: destination
                )
                try await coordinator.enqueue(job)

                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                let task = try adapter.downloadValidated(
                    request,
                    jobID: id,
                    startImmediately: false,
                    mode: .bounded
                )
                do {
                    try await router.bind(BackgroundTransferRoute(
                        taskIdentifier: task.taskIdentifier,
                        jobID: id,
                        kind: .download
                    ))
                    try await adapter.resume(taskIdentifier: task.taskIdentifier)
                } catch {
                    task.cancel()
                    throw error
                }
                activeTaskIdentifier = task.taskIdentifier
                status = "Downloading (id.uuidString)…"
                await refresh()
            } catch {
                status = "Start failed: \(Self.describe(error))"
            }
        }
    }

    func pauseDownload() {
        guard let activeTaskIdentifier else {
            status = "No active download."
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let resumeData = try await adapter.pauseDownload(
                    taskIdentifier: activeTaskIdentifier
                )
                if let job = jobs.first(where: { $0.id == activeJobID }),
                   let resumeData {
                    _ = try await coordinator.pause(
                        id: job.id,
                        resumeData: resumeData
                    )
                }
                status = "Paused; resume data is persisted."
                await refresh()
            } catch {
                status = "Pause failed: \(Self.describe(error))"
            }
        }
    }

    func handleBackgroundEvents(
        identifier: String,
        completionHandler: @escaping @Sendable () -> Void
    ) {
        guard identifier == "com.anotherfuckingnetworkingsdk.background-host" else {
            completionHandler()
            return
        }
        adapter.setBackgroundEventsCompletionHandler(completionHandler)
        Task { await restoreAndReconcile() }
    }

    private var activeJobID: UUID? {
        jobs.first(where: { $0.state == .running || $0.state == .paused })?.id
    }

    private func restoreAndReconcile() async {
        do {
            _ = try await coordinator.restore()
            let report = try await lifecycle.reconcile(adapter: adapter)
            for taskIdentifier in report.orphanedTaskIdentifiers {
                try? await adapter.cancel(taskIdentifier: taskIdentifier)
            }
            for taskIdentifier in report.mismatchedTaskIdentifiers {
                try? await adapter.cancel(taskIdentifier: taskIdentifier)
            }
            status = report.jobsWithoutTasks.isEmpty
                ? "Background tasks restored."
                : "Restore found jobs that need re-enqueue."
            await refresh()
        } catch {
            status = "Restore failed: \(Self.describe(error))"
        }
    }

    private func refresh() async {
        jobs = await coordinator.snapshot()
        let tasks = await adapter.transferTasks()
        activeTaskIdentifier = tasks.first?.taskIdentifier
    }

    private static func destinationURL(for id: UUID) throws -> URL {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(
            "BackgroundTransferHost/Downloads",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent(id.uuidString)
    }

    private static func commitDownload(
        route: BackgroundTransferRoute,
        temporaryURL: URL,
        destination: URL?
    ) async throws -> URL {
        guard let destination else {
            throw BackgroundTransferLifecycleError.missingDownloadDestination(
                route.jobID
            )
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private static func describe(_ error: any Error) -> String {
        String((error as NSError).localizedDescription.prefix(160))
    }
}
