import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("File transfers")
struct FileTransferTests {
    @Test("Data uploads bypass request body encoding and decode metadata")
    func dataUpload() async throws {
        let payload = Data("upload-payload".utf8)
        let capturedRequest = LockedBox<URLRequest?>(nil)
        let responseBody = Data(#"{"id":7,"displayName":"Uploaded"}"#.utf8)
        let stub = StubSession { request in
            capturedRequest.withLock { $0 = request }
            return .respond(try .http(
                for: request,
                statusCode: 201,
                headers: ["X-Upload-ID": "7"],
                data: responseBody
            ))
        }

        let response = try await stub.client().upload(
            UploadFixtureRequest(),
            from: .data(payload)
        )

        let request = try #require(capturedRequest.withLock { $0 })
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Upload-Length") == "14")
        #expect(requestBodyData(request) == payload)
        #expect(response.value == TestUser(id: 7, displayName: "Uploaded"))
        #expect(response.statusCode == 201)
        #expect(response.value(forHTTPHeaderField: "x-upload-id") == "7")
    }

    @Test("File uploads send file bytes and decode the response")
    func fileUpload() async throws {
        let sourceURL = uniqueTemporaryURL()
        let payload = Data([0x00, 0x01, 0xFE, 0xFF])
        try payload.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let capturedBody = LockedBox<Data?>(nil)
        let responseBody = Data(#"{"id":8,"displayName":"File"}"#.utf8)
        let stub = StubSession { request in
            capturedBody.withLock { $0 = requestBodyData(request) }
            return .respond(try .http(for: request, data: responseBody))
        }

        let value = try await stub.client().upload(
            FileUploadFixtureRequest(),
            from: .file(sourceURL)
        ).value

        #expect(capturedBody.withLock { $0 } == payload)
        #expect(value == TestUser(id: 8, displayName: "File"))
    }

    @Test("A non-file upload source fails before transport")
    func invalidUploadSource() async throws {
        let transportCalls = LockedBox(0)
        let stub = StubSession { request in
            transportCalls.withLock { $0 += 1 }
            return .respond(try .http(for: request))
        }
        let sourceURL = try #require(URL(string: "https://example.com/file"))

        do {
            _ = try await stub.client().upload(
                FileUploadFixtureRequest(),
                from: .file(sourceURL)
            )
            Issue.record("Expected an invalid source error")
        } catch let error as NetworkError {
            guard case .fileOperationFailed(let underlying) = error,
                  underlying as? FileTransferError == .sourceIsNotFileURL(sourceURL) else {
                Issue.record("Expected sourceIsNotFileURL, got \(error)")
                return
            }
        }
        #expect(transportCalls.withLock { $0 } == 0)
    }

    @Test("A missing upload file fails before transport")
    func missingUploadSource() async throws {
        let transportCalls = LockedBox(0)
        let stub = StubSession { request in
            transportCalls.withLock { $0 += 1 }
            return .respond(try .http(for: request))
        }
        let sourceURL = uniqueTemporaryURL()

        do {
            _ = try await stub.client().upload(
                FileUploadFixtureRequest(),
                from: .file(sourceURL)
            )
            Issue.record("Expected a missing source error")
        } catch let error as NetworkError {
            guard case .fileOperationFailed(let underlying) = error,
                  underlying as? FileTransferError == .sourceDoesNotExist(sourceURL) else {
                Issue.record("Expected sourceDoesNotExist, got \(error)")
                return
            }
        }
        #expect(transportCalls.withLock { $0 } == 0)
    }

    @Test("Failed uploads preserve HTTP status and response bytes")
    func failedUpload() async throws {
        let errorBody = Data(#"{"message":"too large"}"#.utf8)
        let stub = StubSession { request in
            .respond(try .http(
                for: request,
                statusCode: 413,
                data: errorBody
            ))
        }

        do {
            _ = try await stub.client().upload(
                UploadFixtureRequest(),
                from: .data(Data("payload".utf8))
            )
            Issue.record("Expected an HTTP failure")
        } catch let error as NetworkError {
            guard case .requestFailed(let statusCode, let data) = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
            #expect(statusCode == 413)
            #expect(data == errorBody)
        }
    }

    @Test("Upload cancellation remains CancellationError")
    func uploadCancellation() async throws {
        let started = AsyncSignal()
        let stopped = AsyncSignal()
        let stub = StubSession { _ in
            .pending(
                onStart: { Task { await started.signal() } },
                onStop: { Task { await stopped.signal() } }
            )
        }
        let task = Task {
            try await stub.client().upload(
                FileUploadFixtureRequest(),
                from: .data(Data("payload".utf8))
            )
        }

        await started.wait()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        await stopped.wait()
    }

    @Test("Temporary downloads remain readable after the operation returns")
    func temporaryDownload() async throws {
        let payload = Data("downloaded-file".utf8)
        let capturedRequest = LockedBox<URLRequest?>(nil)
        let stub = StubSession { request in
            capturedRequest.withLock { $0 = request }
            return .respond(try .http(
                for: request,
                statusCode: 206,
                headers: ["ETag": "fixture-tag"],
                data: payload
            ))
        }

        let response = try await stub.client().download(
            DownloadFixtureRequest()
        )
        defer { try? FileManager.default.removeItem(at: response.fileURL) }

        let request = try #require(capturedRequest.withLock { $0 })
        #expect(request.httpMethod == "POST")
        #expect(requestBodyData(request) == Data("request-body".utf8))
        #expect(request.timeoutInterval == 30)
        #expect(try Data(contentsOf: response.fileURL) == payload)
        #expect(response.statusCode == 206)
        #expect(response.value(forHTTPHeaderField: "etag") == "fixture-tag")
    }

    @Test("Downloads move to an explicit destination")
    func explicitDestination() async throws {
        let payload = Data("explicit-destination".utf8)
        let destinationURL = uniqueTemporaryURL()
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let stub = StubSession { request in
            .respond(try .http(for: request, data: payload))
        }

        let response = try await stub.client().download(
            DownloadFixtureRequest(),
            to: .file(destinationURL, overwriteExisting: false)
        )

        #expect(response.fileURL == destinationURL)
        #expect(try Data(contentsOf: destinationURL) == payload)
    }

    @Test("Existing destinations are preserved unless overwrite is explicit")
    func destinationCollision() async throws {
        let destinationURL = uniqueTemporaryURL()
        let original = Data("keep-me".utf8)
        try original.write(to: destinationURL)
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let transportCalls = LockedBox(0)
        let stub = StubSession { request in
            transportCalls.withLock { $0 += 1 }
            return .respond(try .http(
                for: request,
                data: Data("replacement".utf8)
            ))
        }

        do {
            _ = try await stub.client().download(
                DownloadFixtureRequest(),
                to: .file(destinationURL, overwriteExisting: false)
            )
            Issue.record("Expected a destination collision")
        } catch let error as NetworkError {
            guard case .fileOperationFailed(let underlying) = error,
                  underlying as? FileTransferError
                    == .destinationAlreadyExists(destinationURL) else {
                Issue.record("Expected destinationAlreadyExists, got \(error)")
                return
            }
        }

        #expect(transportCalls.withLock { $0 } == 0)
        #expect(try Data(contentsOf: destinationURL) == original)
    }

    @Test("A non-file download destination fails before transport")
    func invalidDownloadDestination() async throws {
        let transportCalls = LockedBox(0)
        let stub = StubSession { request in
            transportCalls.withLock { $0 += 1 }
            return .respond(try .http(for: request))
        }
        let destinationURL = try #require(URL(string: "https://example.com/file"))

        do {
            _ = try await stub.client().download(
                DownloadFixtureRequest(),
                to: .file(destinationURL, overwriteExisting: false)
            )
            Issue.record("Expected an invalid destination error")
        } catch let error as NetworkError {
            guard case .fileOperationFailed(let underlying) = error,
                  underlying as? FileTransferError
                    == .destinationIsNotFileURL(destinationURL) else {
                Issue.record("Expected destinationIsNotFileURL, got \(error)")
                return
            }
        }
        #expect(transportCalls.withLock { $0 } == 0)
    }

    @Test("Destination write failures remain file operation errors")
    func destinationWriteFailure() async throws {
        let ownedDownloadURL = uniqueTemporaryURL()
        try Data("downloaded".utf8).write(to: ownedDownloadURL)
        defer { try? FileManager.default.removeItem(at: ownedDownloadURL) }
        let missingDirectory = uniqueTemporaryURL()
        let destinationURL = missingDirectory.appendingPathComponent("file")
        let stub = StubSession { _ in
            .pending(onStart: {}, onStop: {})
        }
        let client = stub.client(downloadOperation: { request in
            (
                ownedDownloadURL,
                try StubURLProtocol.StubResponse.http(
                    for: request,
                    data: Data("downloaded".utf8)
                ).response
            )
        })

        do {
            _ = try await client.download(
                DownloadFixtureRequest(),
                to: .file(destinationURL, overwriteExisting: false)
            )
            Issue.record("Expected storage to fail")
        } catch let error as NetworkError {
            guard case .fileOperationFailed = error else {
                Issue.record("Expected fileOperationFailed, got \(error)")
                return
            }
        }
        #expect(!FileManager.default.fileExists(atPath: ownedDownloadURL.path))
    }

    @Test("Explicit overwrite replaces an existing destination")
    func overwriteDestination() async throws {
        let destinationURL = uniqueTemporaryURL()
        try Data("old".utf8).write(to: destinationURL)
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let replacement = Data("new".utf8)
        let stub = StubSession { request in
            .respond(try .http(for: request, data: replacement))
        }

        _ = try await stub.client().download(
            DownloadFixtureRequest(),
            to: .file(destinationURL, overwriteExisting: true)
        )

        #expect(try Data(contentsOf: destinationURL) == replacement)
    }

    @Test("Failed downloads preserve bounded HTTP error bytes")
    func failedDownload() async throws {
        let errorBody = Data(#"{"message":"missing"}"#.utf8)
        let ownedDownloadURL = uniqueTemporaryURL()
        try errorBody.write(to: ownedDownloadURL)
        defer { try? FileManager.default.removeItem(at: ownedDownloadURL) }
        let destinationURL = uniqueTemporaryURL()
        let stub = StubSession { _ in
            .pending(onStart: {}, onStop: {})
        }
        let client = stub.client(downloadOperation: { request in
            (
                ownedDownloadURL,
                try StubURLProtocol.StubResponse.http(
                    for: request,
                    statusCode: 404,
                    data: errorBody
                ).response
            )
        })

        do {
            _ = try await client.download(
                DownloadFixtureRequest(),
                to: .file(destinationURL, overwriteExisting: false)
            )
            Issue.record("Expected an HTTP failure")
        } catch let error as NetworkError {
            guard case .requestFailed(let statusCode, let data) = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
            #expect(statusCode == 404)
            #expect(data == errorBody)
        }

        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
        #expect(!FileManager.default.fileExists(atPath: ownedDownloadURL.path))
    }

    @Test("Invalid responses discard the owned download file")
    func invalidResponseDiscardsDownload() async throws {
        let ownedDownloadURL = uniqueTemporaryURL()
        try Data("not-http".utf8).write(to: ownedDownloadURL)
        defer { try? FileManager.default.removeItem(at: ownedDownloadURL) }
        let stub = StubSession { _ in
            .pending(onStart: {}, onStop: {})
        }
        let client = stub.client(downloadOperation: { request in
            let responseURL = try #require(request.url)
            return (
                ownedDownloadURL,
                URLResponse(
                    url: responseURL,
                    mimeType: nil,
                    expectedContentLength: 8,
                    textEncodingName: nil
                )
            )
        })

        do {
            _ = try await client.download(DownloadFixtureRequest())
            Issue.record("Expected a non-HTTP response failure")
        } catch let error as NetworkError {
            guard case .invalidResponse = error else {
                Issue.record("Expected invalidResponse, got \(error)")
                return
            }
        }

        #expect(!FileManager.default.fileExists(atPath: ownedDownloadURL.path))
    }

    @Test("Cancellation before storage discards the owned download file")
    func cancellationDiscardsDownloadBeforeCommit() async throws {
        let ownedDownloadURL = uniqueTemporaryURL()
        try Data("cancelled".utf8).write(to: ownedDownloadURL)
        defer { try? FileManager.default.removeItem(at: ownedDownloadURL) }
        let stub = StubSession { _ in
            .pending(onStart: {}, onStop: {})
        }
        let client = stub.client(downloadOperation: { request in
            withUnsafeCurrentTask { $0?.cancel() }
            return (
                ownedDownloadURL,
                try StubURLProtocol.StubResponse.http(
                    for: request,
                    data: Data("cancelled".utf8)
                ).response
            )
        })

        let task = Task {
            try await client.download(DownloadFixtureRequest())
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation before file storage")
        } catch {
            #expect(error is CancellationError)
        }

        #expect(!FileManager.default.fileExists(atPath: ownedDownloadURL.path))
    }

    @Test("Oversized failed downloads do not load error bodies into memory")
    func oversizedFailedDownload() async throws {
        let errorBody = Data(repeating: 0x41, count: 1_048_577)
        let stub = StubSession { request in
            .respond(try .http(
                for: request,
                statusCode: 500,
                data: errorBody
            ))
        }

        do {
            _ = try await stub.client().download(DownloadFixtureRequest())
            Issue.record("Expected an HTTP failure")
        } catch let error as NetworkError {
            guard case .requestFailed(let statusCode, let data) = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
            #expect(statusCode == 500)
            #expect(data == nil)
        }
    }

    @Test("Download cancellation remains CancellationError")
    func downloadCancellation() async throws {
        let started = AsyncSignal()
        let stopped = AsyncSignal()
        let stub = StubSession { _ in
            .pending(
                onStart: { Task { await started.signal() } },
                onStop: { Task { await stopped.signal() } }
            )
        }
        let task = Task {
            try await stub.client().download(DownloadFixtureRequest())
        }

        await started.wait()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        await stopped.wait()
    }
}

private struct UploadFixtureRequest: Request {
    typealias ReturnType = TestUser

    let path = "uploads/data"
    let method = HTTPMethod.post

    func makeBody(using encoder: JSONEncoder) throws -> Data? {
        throw FileTransferFixtureError.requestBodyMustBeIgnored
    }

    func customize(_ urlRequest: inout URLRequest) throws {
        urlRequest.setValue(
            String(urlRequest.httpBody?.count ?? 0),
            forHTTPHeaderField: "X-Upload-Length"
        )
    }
}

private struct FileUploadFixtureRequest: Request {
    typealias ReturnType = TestUser

    let path = "uploads/file"
    let method = HTTPMethod.put
}

private struct DownloadFixtureRequest: DownloadRequest {
    let path = "downloads/file"
    let method = HTTPMethod.post
    let body: Data? = Data("request-body".utf8)

    func customize(_ urlRequest: inout URLRequest) throws {
        urlRequest.timeoutInterval = 30
    }
}

private enum FileTransferFixtureError: Error {
    case requestBodyMustBeIgnored
}

private func uniqueTemporaryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "afnsdk-\(UUID().uuidString)",
        isDirectory: false
    )
}
