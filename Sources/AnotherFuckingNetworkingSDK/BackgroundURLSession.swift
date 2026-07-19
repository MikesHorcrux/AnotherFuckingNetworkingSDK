#if !os(tvOS) && !os(watchOS) && !os(visionOS)
import Foundation

/// Privacy-safe events emitted by a background URLSession delegate.
public enum BackgroundTransferEvent: Equatable, Sendable {
    case uploadProgress(
        taskIdentifier: Int,
        bytesSent: Int64,
        totalBytes: Int64
    )
    case downloadProgress(
        taskIdentifier: Int,
        bytesWritten: Int64,
        totalBytes: Int64
    )
    case downloadFinished(
        taskIdentifier: Int,
        temporaryURL: URL
    )
    case completed(
        taskIdentifier: Int,
        errorDescription: String?,
        resumeData: Data?
    )
    case metrics(
        taskIdentifier: Int,
        snapshot: NetworkTaskMetricsSnapshot
    )
    case backgroundEventsFinished

    /// The Foundation task identifier carried by task-scoped events.
    public var taskIdentifier: Int? {
        switch self {
        case .uploadProgress(let taskIdentifier, _, _),
             .downloadProgress(let taskIdentifier, _, _),
             .downloadFinished(let taskIdentifier, _),
             .completed(let taskIdentifier, _, _),
             .metrics(let taskIdentifier, _):
            return taskIdentifier
        case .backgroundEventsFinished:
            return nil
        }
    }

    /// Whether the event ends work for one task or for the background session.
    public var isTerminal: Bool {
        switch self {
        case .completed, .backgroundEventsFinished:
            return true
        case .uploadProgress, .downloadProgress, .downloadFinished, .metrics:
            return false
        }
    }
}

/// A stable, relaunch-safe description of a task discovered in a background
/// session. The optional job ID is encoded in the task description when a
/// transfer is started through ``BackgroundURLSessionAdapter``.
public struct BackgroundTransferTaskDescriptor: Codable, Equatable, Sendable {
    public let taskIdentifier: Int
    public let jobID: UUID?
    public let originalURL: URL?
    public let isDownload: Bool

    public init(
        taskIdentifier: Int,
        jobID: UUID? = nil,
        originalURL: URL? = nil,
        isDownload: Bool
    ) {
        self.taskIdentifier = taskIdentifier
        self.jobID = jobID
        self.originalURL = originalURL
        self.isDownload = isDownload
    }
}

/// Selects how strictly opaque Foundation resume data is checked.
public enum BackgroundTransferResumeDataValidationMode: Sendable {
    /// Check only the non-empty and bounded contract. This is the compatible
    /// default because Foundation owns the opaque resume-data format.
    case bounded

    /// Also require a property-list root, matching the current Foundation
    /// representation while keeping strict validation opt-in for callers.
    case propertyList
}

/// Errors raised while validating persisted Foundation resume data.
public enum BackgroundTransferResumeDataValidationError: LocalizedError,
    Equatable,
    Sendable
{
    case invalidMaximumBytes(Int)
    case empty
    case tooLarge(maximumBytes: Int, actualBytes: Int)
    case malformedPropertyList

    public var errorDescription: String? {
        switch self {
        case .invalidMaximumBytes(let value):
            return "The resume-data maximum must be positive, not \(value)."
        case .empty:
            return "Background resume data cannot be empty."
        case .tooLarge(let maximumBytes, let actualBytes):
            return "Background resume data is \(actualBytes) bytes; the maximum is \(maximumBytes)."
        case .malformedPropertyList:
            return "Background resume data is not a valid property list."
        }
    }
}

/// Validates bounded, opaque Foundation resume data before persistence or
/// relaunch. The default mode preserves forward compatibility with future
/// Foundation formats; property-list validation is available as an opt-in
/// integrity check when the application controls its stored data.
public struct BackgroundTransferResumeDataValidator: Sendable, Equatable {
    public static let defaultMaximumBytes = 8 * 1_024 * 1_024

    public let maximumBytes: Int

    public init(
        maximumBytes: Int = BackgroundTransferResumeDataValidator.defaultMaximumBytes
    ) throws {
        guard maximumBytes > 0 else {
            throw BackgroundTransferResumeDataValidationError.invalidMaximumBytes(
                maximumBytes
            )
        }
        self.maximumBytes = maximumBytes
    }

    /// Returns the original value after applying the selected validation.
    public func validate(
        _ data: Data?,
        mode: BackgroundTransferResumeDataValidationMode = .bounded
    ) throws -> Data? {
        guard let data else { return nil }
        guard !data.isEmpty else {
            throw BackgroundTransferResumeDataValidationError.empty
        }
        guard data.count <= maximumBytes else {
            throw BackgroundTransferResumeDataValidationError.tooLarge(
                maximumBytes: maximumBytes,
                actualBytes: data.count
            )
        }

        if case .propertyList = mode {
            do {
                _ = try PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                )
            } catch {
                throw BackgroundTransferResumeDataValidationError
                    .malformedPropertyList
            }
        }
        return data
    }
}

/// Errors raised when an app-owned background task control cannot be applied.
public enum BackgroundTransferTaskControlError: LocalizedError,
    Equatable,
    Sendable
{
    case taskNotFound(Int)
    case notDownloadTask(Int)

    public var errorDescription: String? {
        switch self {
        case .taskNotFound(let taskIdentifier):
            return "Background task \(taskIdentifier) was not found."
        case .notDownloadTask(let taskIdentifier):
            return "Background task \(taskIdentifier) is not a download task."
        }
    }
}

/// A callback-facing delegate for an app-owned background URLSession.
///
/// The delegate emits task identifiers, byte counts, temporary download URLs,
/// and bounded textual failure details. It never stores requests, credentials,
/// response bodies, or application state. Keep the instance alive for the
/// lifetime of its session; ``BackgroundURLSessionAdapter`` does that for you.
public final class BackgroundURLSessionDelegate: NSObject,
    URLSessionDownloadDelegate,
    URLSessionTaskDelegate,
    URLSessionDelegate,
    @unchecked Sendable {
    public typealias EventHandler = @Sendable (BackgroundTransferEvent) -> Void
    public typealias CompletionHandler = @Sendable () -> Void

    private let eventHandler: EventHandler
    private let completionHandler = CriticalState<CompletionHandler?>(nil)

    public init(eventHandler: @escaping EventHandler) {
        self.eventHandler = eventHandler
    }

    /// Stores the system completion handler until all delegate work is drained.
    public func setBackgroundEventsCompletionHandler(
        _ handler: @escaping CompletionHandler
    ) {
        completionHandler.withCriticalRegion { $0 = handler }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        eventHandler(.uploadProgress(
            taskIdentifier: task.taskIdentifier,
            bytesSent: max(0, totalBytesSent),
            totalBytes: max(0, totalBytesExpectedToSend)
        ))
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        eventHandler(.downloadProgress(
            taskIdentifier: downloadTask.taskIdentifier,
            bytesWritten: max(0, totalBytesWritten),
            totalBytes: max(0, totalBytesExpectedToWrite)
        ))
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        eventHandler(.downloadFinished(
            taskIdentifier: downloadTask.taskIdentifier,
            temporaryURL: location
        ))
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let candidateResumeData = (error as NSError?)?.userInfo[
            NSURLSessionDownloadTaskResumeData
        ] as? Data
        let resumeData = candidateResumeData.flatMap {
            $0.count <= transferResumeDataLimitBytes ? $0 : nil
        }
        let description: String?
        if let error {
            let nsError = error as NSError
            description = "\(nsError.domain) (\(nsError.code))"
        } else {
            description = nil
        }
        eventHandler(.completed(
            taskIdentifier: task.taskIdentifier,
            errorDescription: description,
            resumeData: resumeData
        ))
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        eventHandler(.metrics(
            taskIdentifier: task.taskIdentifier,
            snapshot: NetworkTaskMetricsSnapshot(metrics)
        ))
    }

    public func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession
    ) {
        eventHandler(.backgroundEventsFinished)
        let handler = completionHandler.withCriticalRegion { value in
            defer { value = nil }
            return value
        }
        handler?()
    }
}

/// Owns a background URLSession and its lifecycle delegate.
///
/// Request construction, authentication, durable job persistence, and moving
/// downloaded files remain application/coordinator responsibilities. The
/// adapter only creates Foundation tasks and translates delegate callbacks.
public final class BackgroundURLSessionAdapter: Sendable {
    private static let taskDescriptionPrefix = "afn-transfer-job:"

    public let session: URLSession
    public let delegate: BackgroundURLSessionDelegate

    public init(
        identifier: String,
        eventHandler: @escaping BackgroundURLSessionDelegate.EventHandler,
        delegateQueue: OperationQueue? = nil
    ) {
        delegate = BackgroundURLSessionDelegate(eventHandler: eventHandler)
        let configuration = URLSessionConfiguration.background(
            withIdentifier: identifier
        )
        session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: delegateQueue
        )
    }

    /// Starts a background upload from a stable file URL.
    public func upload(
        _ request: URLRequest,
        fromFile fileURL: URL,
        jobID: UUID? = nil
    ) -> URLSessionUploadTask {
        let task = session.uploadTask(with: request, fromFile: fileURL)
        configure(task, jobID: jobID)
        task.resume()
        return task
    }

    /// Starts a new download or resumes Foundation resume data.
    public func download(
        _ request: URLRequest,
        resumeData: Data? = nil,
        jobID: UUID? = nil
    ) -> URLSessionDownloadTask {
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: request)
        }
        configure(task, jobID: jobID)
        task.resume()
        return task
    }

    /// Validates optional resume data before creating a Foundation download
    /// task. Use `.propertyList` only when the application wants strict
    /// integrity checking for the current Foundation representation.
    public func downloadValidated(
        _ request: URLRequest,
        resumeData: Data? = nil,
        jobID: UUID? = nil,
        mode: BackgroundTransferResumeDataValidationMode = .bounded
    ) throws -> URLSessionDownloadTask {
        let validated = try BackgroundTransferResumeDataValidator().validate(
            resumeData,
            mode: mode
        )
        return download(
            request,
            resumeData: validated,
            jobID: jobID
        )
    }

    /// Returns the tasks currently owned by the background session.
    ///
    /// Call this after relaunch before restoring jobs. The descriptor reads
    /// only stable task metadata and never exposes a request body or headers.
    public func transferTasks() async -> [BackgroundTransferTaskDescriptor] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: tasks.map { task in
                    BackgroundTransferTaskDescriptor(
                        taskIdentifier: task.taskIdentifier,
                        jobID: Self.jobID(from: task.taskDescription),
                        originalURL: task.originalRequest?.url,
                        isDownload: task is URLSessionDownloadTask
                    )
                })
            }
        }
    }

    /// Cancels a download and returns bounded Foundation resume data when it
    /// is available. The durable job remains the caller's source of truth.
    public func pauseDownload(taskIdentifier: Int) async throws -> Data? {
        let task = try await task(withIdentifier: taskIdentifier)
        guard let downloadTask = task as? URLSessionDownloadTask else {
            throw BackgroundTransferTaskControlError.notDownloadTask(
                taskIdentifier
            )
        }

        return await withCheckedContinuation { continuation in
            downloadTask.cancel { resumeData in
                continuation.resume(returning: resumeData.flatMap {
                    $0.count <= transferResumeDataLimitBytes ? $0 : nil
                })
            }
        }
    }

    /// Cancels a task without asking Foundation to produce resume data.
    public func cancel(taskIdentifier: Int) async throws {
        let task = try await task(withIdentifier: taskIdentifier)
        task.cancel()
    }

    /// Resumes a task discovered from the current background session.
    public func resume(taskIdentifier: Int) async throws {
        let task = try await task(withIdentifier: taskIdentifier)
        task.resume()
    }

    /// Installs the app delegate's background completion handler.
    public func setBackgroundEventsCompletionHandler(
        _ handler: @escaping BackgroundURLSessionDelegate.CompletionHandler
    ) {
        delegate.setBackgroundEventsCompletionHandler(handler)
    }

    public func finishTasksAndInvalidate() {
        session.finishTasksAndInvalidate()
    }

    public func invalidateAndCancel() {
        session.invalidateAndCancel()
    }

    private func task(withIdentifier taskIdentifier: Int) async throws
        -> URLSessionTask {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URLSessionTask, Error>) in
            session.getAllTasks { tasks in
                guard let task = tasks.first(where: {
                    $0.taskIdentifier == taskIdentifier
                }) else {
                    continuation.resume(throwing:
                        BackgroundTransferTaskControlError.taskNotFound(
                            taskIdentifier
                        )
                    )
                    return
                }
                continuation.resume(returning: task)
            }
        }
    }

    private func configure(_ task: URLSessionTask, jobID: UUID?) {
        if let jobID {
            task.taskDescription = Self.taskDescription(for: jobID)
        }
    }

    private static func taskDescription(for jobID: UUID) -> String {
        taskDescriptionPrefix + jobID.uuidString
    }

    private static func jobID(from taskDescription: String?) -> UUID? {
        guard let taskDescription,
              taskDescription.hasPrefix(taskDescriptionPrefix) else {
            return nil
        }
        return UUID(
            uuidString: String(
                taskDescription.dropFirst(taskDescriptionPrefix.count)
            )
        )
    }
}
#endif
