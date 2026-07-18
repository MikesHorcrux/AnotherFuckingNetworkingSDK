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
    case backgroundEventsFinished
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
        let resumeData = (error as NSError?)?.userInfo[
            NSURLSessionDownloadTaskResumeData
        ] as? Data
        let description = error.map { String(describing: $0) }
        eventHandler(.completed(
            taskIdentifier: task.taskIdentifier,
            errorDescription: description,
            resumeData: resumeData
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
        fromFile fileURL: URL
    ) -> URLSessionUploadTask {
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.resume()
        return task
    }

    /// Starts a new download or resumes Foundation resume data.
    public func download(
        _ request: URLRequest,
        resumeData: Data? = nil
    ) -> URLSessionDownloadTask {
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: request)
        }
        task.resume()
        return task
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
}
