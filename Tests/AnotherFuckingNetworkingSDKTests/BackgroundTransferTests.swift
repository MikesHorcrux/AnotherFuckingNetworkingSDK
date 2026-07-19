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

    @Test("Resume data is bounded at construction and JSON restore")
    func resumeDataIsBounded() async throws {
        let oversized = Data(repeating: 1, count: 8 * 1_024 * 1_024 + 1)
        let direct = TransferJob(
            kind: .download,
            requestKey: "large",
            resumeData: oversized
        )
        #expect(direct.resumeData == nil)

        let seed = TransferJob(
            kind: .download,
            requestKey: "large",
            resumeData: Data([1])
        )
        var object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(seed)
            ) as? [String: Any]
        )
        object["resumeData"] = oversized.base64EncodedString()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("afn-transfer-resume-(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: [object]).write(to: url)

        let restored = try await JSONTransferJobStore(fileURL: url).loadAll()
        #expect(restored.first?.resumeData == nil)
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

    @Test("Failed jobs persist bounded error identity without sensitive text")
    func failurePersistsSafeErrorIdentity() async throws {
        let store = InMemoryTransferJobStore()
        let coordinator = TransferJobCoordinator(store: store)
        let job = TransferJob(kind: .download, requestKey: "private-export")
        try await coordinator.enqueue(job)

        do {
            _ = try await coordinator.execute(id: job.id) { _, _ in
                throw NSError(
                    domain: "com.example.server",
                    code: 503,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Authorization: Bearer secret-response-body"
                    ]
                )
            }
            Issue.record("Expected transfer failure")
        } catch let error as NSError {
            #expect(error.domain == "com.example.server")
            #expect(error.code == 503)
        }

        let failed = try #require(await coordinator.snapshot().first)
        #expect(failed.state == .failed)
        #expect(failed.lastError == "com.example.server (503)")
        #expect(failed.lastError?.contains("secret") == false)
    }
}
