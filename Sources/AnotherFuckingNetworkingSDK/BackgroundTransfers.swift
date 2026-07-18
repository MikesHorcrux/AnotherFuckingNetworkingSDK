import Foundation

let transferResumeDataLimitBytes = 8 * 1_024 * 1_024

private func boundedTransferResumeData(_ data: Data?) -> Data? {
    guard let data, data.count <= transferResumeDataLimitBytes else {
        return nil
    }
    return data
}

private func boundedTransferErrorSummary(_ value: String?) -> String? {
    guard let value else { return nil }
    return String(value.prefix(512))
}

/// The durable direction of a background transfer job.
public enum TransferJobKind: String, Codable, Equatable, Sendable {
    case upload
    case download
}

/// The persisted lifecycle state of a transfer job.
public enum TransferJobState: String, Codable, Equatable, Sendable {
    case queued
    case running
    case paused
    case succeeded
    case failed
    case cancelled
}

/// A Sendable, Codable description of work that can survive process relaunch.
///
/// The SDK intentionally stores a stable application-defined `requestKey`
/// rather than attempting to encode an arbitrary request value. On relaunch,
/// the application resolves that key to a request and an execution closure.
public struct TransferJob: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: TransferJobKind
    public let requestKey: String
    public let createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var state: TransferJobState
    public private(set) var bytesCompleted: Int64
    public private(set) var totalBytes: Int64?
    public private(set) var attempt: Int
    public private(set) var resumeData: Data?
    public private(set) var destinationURL: URL?
    public private(set) var lastError: String?

    public init(
        id: UUID = UUID(),
        kind: TransferJobKind,
        requestKey: String,
        createdAt: Date = Date(),
        state: TransferJobState = .queued,
        bytesCompleted: Int64 = 0,
        totalBytes: Int64? = nil,
        attempt: Int = 1,
        resumeData: Data? = nil,
        destinationURL: URL? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.requestKey = requestKey
        self.createdAt = createdAt
        updatedAt = createdAt
        self.state = state
        self.bytesCompleted = max(0, bytesCompleted)
        self.totalBytes = totalBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.attempt = max(1, attempt)
        self.resumeData = boundedTransferResumeData(resumeData)
        self.destinationURL = destinationURL
        self.lastError = boundedTransferErrorSummary(lastError)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, requestKey, createdAt, updatedAt, state
        case bytesCompleted, totalBytes, attempt, resumeData
        case destinationURL, lastError
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            kind: try container.decode(TransferJobKind.self, forKey: .kind),
            requestKey: try container.decode(String.self, forKey: .requestKey),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            state: try container.decode(TransferJobState.self, forKey: .state),
            bytesCompleted: try container.decode(Int64.self, forKey: .bytesCompleted),
            totalBytes: try container.decodeIfPresent(Int64.self, forKey: .totalBytes),
            attempt: try container.decode(Int.self, forKey: .attempt),
            resumeData: try container.decodeIfPresent(Data.self, forKey: .resumeData),
            destinationURL: try container.decodeIfPresent(URL.self, forKey: .destinationURL),
            lastError: try container.decodeIfPresent(String.self, forKey: .lastError)
        )
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    /// Applies an observed progress event without changing terminal state.
    public mutating func record(
        _ update: TransferJobUpdate,
        now: Date = Date()
    ) {
        bytesCompleted = max(bytesCompleted, update.progress.bytesCompleted)
        if let totalBytes = update.progress.totalBytes {
            self.totalBytes = totalBytes
        }
        attempt = max(attempt, update.progress.attempt)
        resumeData = boundedTransferResumeData(update.resumeData) ?? resumeData
        destinationURL = update.destinationURL ?? destinationURL
        updatedAt = now
    }

    fileprivate mutating func markRunning(now: Date) {
        if state != .queued {
            if attempt < Int.max {
                attempt += 1
            }
        }
        state = .running
        lastError = nil
        updatedAt = now
    }

    fileprivate mutating func markPaused(
        resumeData: Data?,
        now: Date
    ) {
        state = .paused
        self.resumeData = boundedTransferResumeData(resumeData) ?? self.resumeData
        updatedAt = now
    }

    fileprivate mutating func markCancelled(now: Date) {
        state = .cancelled
        updatedAt = now
    }

    fileprivate mutating func markSucceeded(
        result: TransferJobResult,
        now: Date
    ) {
        state = .succeeded
        bytesCompleted = max(bytesCompleted, result.bytesCompleted)
        totalBytes = result.totalBytes ?? totalBytes
        resumeData = nil
        destinationURL = result.destinationURL ?? destinationURL
        lastError = nil
        updatedAt = now
    }

    fileprivate mutating func markFailed(
        _ error: any Error,
        now: Date
    ) {
        state = .failed
        // Durable job state can outlive the process and may be inspected or
        // synced by application code. Persist only a bounded NSError identity
        // instead of arbitrary localized/reflected error text, which can
        // contain response bodies, file paths, credentials, or user data.
        let nsError = error as NSError
        let domain = String(nsError.domain.prefix(128))
        lastError = boundedTransferErrorSummary(
            domain + " (" + String(nsError.code) + ")"
        )
        updatedAt = now
    }
}

/// A progress update that can also preserve platform resume data.
public struct TransferJobUpdate: Sendable {
    public let progress: TransferProgress
    public let resumeData: Data?
    public let destinationURL: URL?

    public init(
        progress: TransferProgress,
        resumeData: Data? = nil,
        destinationURL: URL? = nil
    ) {
        self.progress = progress
        self.resumeData = resumeData
        self.destinationURL = destinationURL
    }
}

/// The successful result returned by a durable transfer operation.
public struct TransferJobResult: Sendable {
    public let bytesCompleted: Int64
    public let totalBytes: Int64?
    public let destinationURL: URL?

    public init(
        bytesCompleted: Int64,
        totalBytes: Int64? = nil,
        destinationURL: URL? = nil
    ) {
        self.bytesCompleted = max(0, bytesCompleted)
        self.totalBytes = totalBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.destinationURL = destinationURL
    }
}

/// An async persistence boundary for durable transfer records.
public protocol TransferJobStore: Sendable {
    func loadAll() async throws -> [TransferJob]
    func save(_ job: TransferJob) async throws
    func remove(id: UUID) async throws
}

/// An actor-backed store for deterministic tests and previews.
public actor InMemoryTransferJobStore: TransferJobStore {
    private var jobs: [UUID: TransferJob] = [:]

    public init() {}

    public func loadAll() async throws -> [TransferJob] {
        jobs.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func save(_ job: TransferJob) async throws {
        jobs[job.id] = job
    }

    public func remove(id: UUID) async throws {
        jobs.removeValue(forKey: id)
    }
}

/// A JSON-backed store that writes the complete index atomically.
public actor JSONTransferJobStore: TransferJobStore {
    private let fileURL: URL
    private let fileIOExecutor: FileIOExecutor

    public init(fileURL: URL) {
        self.fileURL = fileURL
        fileIOExecutor = .shared
    }

    public func loadAll() async throws -> [TransferJob] {
        let url = fileURL
        return try await fileIOExecutor.run {
            guard FileManager.default.fileExists(atPath: url.path) else {
                return []
            }
            do {
                return try JSONDecoder().decode(
                    [TransferJob].self,
                    from: Data(contentsOf: url)
                )
            } catch {
                throw TransferJobStoreError.corruptDocument
            }
        }
    }

    public func save(_ job: TransferJob) async throws {
        var jobs = try await loadAll()
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.append(job)
        }
        try await write(jobs.sorted { $0.createdAt < $1.createdAt })
    }

    public func remove(id: UUID) async throws {
        let jobs = try await loadAll().filter { $0.id != id }
        try await write(jobs)
    }

    private func write(_ jobs: [TransferJob]) async throws {
        let url = fileURL
        let data: Data
        do {
            data = try JSONEncoder().encode(jobs)
        } catch {
            throw TransferJobStoreError.encodingFailed
        }
        try await fileIOExecutor.runCommitted {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
    }
}

/// Errors raised by a durable job store.
public enum TransferJobStoreError: LocalizedError, Equatable, Sendable {
    case corruptDocument
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .corruptDocument:
            return "The transfer job store contains invalid JSON."
        case .encodingFailed:
            return "The transfer job store could not encode a job document."
        }
    }
}

/// A closure that executes one transfer and reports resumable checkpoints.
public typealias TransferJobOperation = @Sendable (
    TransferJob,
    @escaping @Sendable (TransferJobUpdate) async throws -> Void
) async throws -> TransferJobResult

/// Coordinates durable state transitions around a caller-owned transfer.
///
/// The coordinator does not create a second URLSession stack. Applications
/// provide the operation, which can use `APIClient` or a platform background
/// session, while this actor persists queue, pause, success, and failure state.
public actor TransferJobCoordinator {
    private let store: any TransferJobStore
    private var jobs: [UUID: TransferJob] = [:]
    private var running: Set<UUID> = []

    public init(store: any TransferJobStore) {
        self.store = store
    }

    /// Restores the durable index after application launch.
    @discardableResult
    public func restore() async throws -> [TransferJob] {
        jobs = try await store.loadAll().reduce(into: [:]) { result, job in
            result[job.id] = job
        }
        return snapshot()
    }

    public func snapshot() -> [TransferJob] {
        jobs.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func enqueue(_ job: TransferJob) async throws {
        guard jobs[job.id] == nil else { return }
        jobs[job.id] = job
        try await store.save(job)
    }

    public func cancel(id: UUID) async throws {
        guard !running.contains(id) else {
            throw TransferJobCoordinatorError.jobRunning(id)
        }
        guard var job = jobs[id] else { return }
        job.markCancelled(now: Date())
        jobs[id] = job
        try await store.save(job)
    }

    public func remove(id: UUID) async throws {
        jobs.removeValue(forKey: id)
        try await store.remove(id: id)
    }

    /// Runs one job and persists every lifecycle boundary.
    @discardableResult
    public func execute(
        id: UUID,
        operation: @escaping TransferJobOperation
    ) async throws -> TransferJob {
        guard !running.contains(id), var job = jobs[id] else {
            throw TransferJobCoordinatorError.jobUnavailable(id)
        }
        running.insert(id)
        defer { running.remove(id) }

        job.markRunning(now: Date())
        jobs[id] = job
        try await store.save(job)

        do {
            let result = try await operation(job) { [self] update in
                try await record(id: id, update: update)
            }
            guard var finished = jobs[id] else {
                throw TransferJobCoordinatorError.jobUnavailable(id)
            }
            finished.markSucceeded(result: result, now: Date())
            jobs[id] = finished
            try await store.save(finished)
            return finished
        } catch is CancellationError {
            guard var paused = jobs[id] else {
                throw CancellationError()
            }
            paused.markPaused(resumeData: paused.resumeData, now: Date())
            jobs[id] = paused
            try await store.save(paused)
            throw CancellationError()
        } catch {
            guard var failed = jobs[id] else { throw error }
            failed.markFailed(error, now: Date())
            jobs[id] = failed
            try await store.save(failed)
            throw error
        }
    }

    private func record(id: UUID, update: TransferJobUpdate) async throws {
        guard var job = jobs[id], !job.state.isTerminal else { return }
        job.record(update)
        jobs[id] = job
        try await store.save(job)
    }
}

private extension TransferJobState {
    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            return true
        case .queued, .running, .paused:
            return false
        }
    }
}

/// Errors raised when a coordinator cannot start or find a job.
public enum TransferJobCoordinatorError: LocalizedError, Equatable, Sendable {
    case jobUnavailable(UUID)
    case jobRunning(UUID)

    public var errorDescription: String? {
        switch self {
        case .jobUnavailable(let id):
            return "Transfer job \(id.uuidString) is unavailable or already running."
        case .jobRunning(let id):
            return "Transfer job \(id.uuidString) is already running; cancel its task to pause it."
        }
    }
}
