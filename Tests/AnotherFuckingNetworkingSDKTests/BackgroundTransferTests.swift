import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("Durable transfer jobs")
struct BackgroundTransferTests {
    @Test("In-memory stores preserve job identity and ordering")
    func inMemoryStore() async throws {
        let store = InMemoryTransferJobStore()
        let first = TransferJob(
            kind: .download,
            requestKey: "avatar-1",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let second = TransferJob(
            kind: .upload,
            requestKey: "avatar-2",
            createdAt: Date(timeIntervalSince1970: 2)
        )

        try await store.save(second)
        try await store.save(first)

        #expect(try await store.loadAll() == [first, second])
        try await store.remove(id: first.id)
        #expect(try await store.loadAll() == [second])
    }

    @Test("JSON stores survive a new actor instance")
    func jsonStore() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("afn-transfer-jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let job = TransferJob(
            kind: .download,
            requestKey: "export",
            resumeData: Data([1, 2, 3]),
            destinationURL: URL(fileURLWithPath: "/tmp/export.bin")
        )
        try await JSONTransferJobStore(fileURL: url).save(job)

        let restored = try await JSONTransferJobStore(fileURL: url).loadAll()
        #expect(restored == [job])
    }

    @Test("Coordinator persists progress and a committed success")
    func successfulExecution() async throws {
        let store = InMemoryTransferJobStore()
        let coordinator = TransferJobCoordinator(store: store)
        let job = TransferJob(kind: .download, requestKey: "file")
        try await coordinator.enqueue(job)

        let finished = try await coordinator.execute(id: job.id) { _, update in
            try await update(TransferJobUpdate(
                progress: TransferProgress(
                    operation: .download,
                    phase: .running,
                    bytesCompleted: 4,
                    totalBytes: 8,
                    attempt: 2
                ),
                resumeData: Data([9]),
                destinationURL: URL(fileURLWithPath: "/tmp/file")
            ))
            return TransferJobResult(
                bytesCompleted: 8,
                totalBytes: 8,
                destinationURL: URL(fileURLWithPath: "/tmp/file")
            )
        }

        #expect(finished.state == .succeeded)
        #expect(finished.bytesCompleted == 8)
        #expect(finished.attempt == 2)
        #expect(finished.resumeData == nil)
        #expect(finished.destinationURL?.path == "/tmp/file")
        #expect(await coordinator.snapshot() == [finished])
    }

    @Test("Cancellation pauses a job and keeps its last checkpoint")
    func cancellationPersistsPause() async throws {
        let store = InMemoryTransferJobStore()
        let coordinator = TransferJobCoordinator(store: store)
        let job = TransferJob(kind: .upload, requestKey: "large-file")
        try await coordinator.enqueue(job)

        let started = AsyncSignal()
        let task = Task {
            try await coordinator.execute(id: job.id) { _, update in
                try await update(TransferJobUpdate(
                    progress: TransferProgress(
                        operation: .upload,
                        phase: .running,
                        bytesCompleted: 5,
                        totalBytes: 10
                    ),
                    resumeData: Data([7, 7])
                ))
                await started.signal()
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return TransferJobResult(bytesCompleted: 10, totalBytes: 10)
            }
        }

        #expect(await started.wait())
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let paused = try #require(await coordinator.snapshot().first)
        #expect(paused.state == .paused)
        #expect(paused.bytesCompleted == 5)
        #expect(paused.resumeData == Data([7, 7]))
    }
}
