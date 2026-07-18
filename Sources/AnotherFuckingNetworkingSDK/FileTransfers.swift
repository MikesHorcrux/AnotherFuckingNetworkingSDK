import Foundation

/// The bytes supplied to an HTTP upload task.
public enum UploadBody: Equatable, Sendable {
    /// Uploads in-memory bytes.
    case data(Data)

    /// Uploads a file without first loading it into memory.
    case file(URL)

    /// Streams a bounded multipart envelope from memory and file-backed parts.
    case multipart(StreamingMultipartFormData)
}

/// The direction of a file transfer progress event.
public enum TransferProgressOperation: String, Equatable, Sendable {
    case upload
    case download
}

/// The lifecycle phase represented by a transfer progress event.
public enum TransferProgressPhase: String, Equatable, Sendable {
    case started
    case running
    case completed
    case failed
    case cancelled
}

/// A bounded, Sendable progress value for an upload or download attempt.
public struct TransferProgress: Equatable, Sendable {
    public let operation: TransferProgressOperation
    public let phase: TransferProgressPhase
    public let bytesCompleted: Int64
    public let totalBytes: Int64?
    public let attempt: Int

    public init(
        operation: TransferProgressOperation,
        phase: TransferProgressPhase,
        bytesCompleted: Int64,
        totalBytes: Int64? = nil,
        attempt: Int = 1
    ) {
        self.operation = operation
        self.phase = phase
        self.bytesCompleted = max(0, bytesCompleted)
        self.totalBytes = totalBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.attempt = max(1, attempt)
    }

    /// A fraction in `0...1` when the server supplied a known total.
    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else {
            return totalBytes == 0 ? 1 : nil
        }
        return min(1, max(0, Double(bytesCompleted) / Double(totalBytes)))
    }
}

/// A lightweight callback used by the opt-in transfer progress APIs.
///
/// Handlers run on URLSession's callback context and should do minimal work.
/// Move expensive UI or persistence work to the caller's own actor/task.
public typealias TransferProgressHandler = @Sendable (TransferProgress) -> Void

/// A type-safe description of an HTTP operation that downloads to disk.
public protocol DownloadRequest: HTTPRequest {}

/// Where a completed download should be stored before it is returned.
public enum DownloadDestination: Equatable, Sendable {
    /// Moves the download to an SDK-owned unique location in the system
    /// temporary directory. The caller is responsible for removing it.
    case temporary

    /// Moves the download to a caller-owned file URL.
    ///
    /// When `overwriteExisting` is `false`, an existing item is preserved and
    /// the operation fails. When it is `true`, the existing item is replaced.
    case file(URL, overwriteExisting: Bool)
}

/// A completed disk-backed download and its HTTP response metadata.
public struct DownloadResponse: Equatable, Sendable {
    public let fileURL: URL
    public let metadata: HTTPResponseMetadata

    public init(fileURL: URL, metadata: HTTPResponseMetadata) {
        self.fileURL = fileURL
        self.metadata = metadata
    }

    public var statusCode: Int { metadata.statusCode }
    public var url: URL? { metadata.url }
    public var headers: [String: String] { metadata.headers }

    public func value(forHTTPHeaderField name: String) -> String? {
        metadata.value(forHTTPHeaderField: name)
    }
}

/// A caller-correctable file location error from an upload or download.
public enum FileTransferError: LocalizedError, Equatable, Sendable {
    case sourceIsNotFileURL(URL)
    case sourceDoesNotExist(URL)
    case sourceIsNotReadableFile(URL)
    case destinationIsNotFileURL(URL)
    case destinationAlreadyExists(URL)

    public var errorDescription: String? {
        switch self {
        case .sourceIsNotFileURL:
            return "The upload source must be a file URL."
        case .sourceDoesNotExist:
            return "The upload source does not exist."
        case .sourceIsNotReadableFile:
            return "The upload source must be a readable regular file."
        case .destinationIsNotFileURL:
            return "The download destination must be a file URL."
        case .destinationAlreadyExists:
            return "The download destination already exists."
        }
    }
}
