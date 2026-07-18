import Foundation
import Testing
import AnotherFuckingNetworkingSDK
import AnotherFuckingNetworkingSDKTesting

@Suite("Mock transfer support")
struct MockTransferTests {
    @Test("Transfer mocks inject through the protocol and exact stubs win")
    func existentialInjectionAndPrecedence() async throws {
        let mock = MockAPIClient()
        let client: any APIClientTransferProtocol = mock
        let exactUpload = MockTransferUploadRequest(id: 1)
        let exactBody = UploadBody.data(Data("exact".utf8))

        await mock.stubUpload(
            MockTransferUploadRequest.self,
            with: uploadResponse(id: 0)
        )
        try await mock.stubUploadError(
            exactUpload,
            from: exactBody,
            error: MockTransferFixtureError.exactUpload
        )

        let fallback = try await client.upload(
            MockTransferUploadRequest(id: 2),
            from: .data(Data("fallback".utf8))
        )
        #expect(fallback.value.id == 0)

        do {
            _ = try await client.upload(exactUpload, from: exactBody)
            Issue.record("Expected the exact upload failure")
        } catch let error as MockTransferFixtureError {
            #expect(error == .exactUpload)
        }

        try await mock.stubUpload(
            exactUpload,
            from: exactBody,
            with: uploadResponse(id: 1)
        )
        #expect(try await client.upload(exactUpload, from: exactBody).value.id == 1)

        let exactDownload = MockTransferDownloadRequest(id: 7)
        let destination = DownloadDestination.file(
            mockFileURL("exact-download"),
            overwriteExisting: false
        )
        await mock.stubDownloadError(
            MockTransferDownloadRequest.self,
            error: MockTransferFixtureError.typeDownload
        )
        try await mock.stubDownload(
            exactDownload,
            to: destination,
            with: downloadResponse("exact-response")
        )

        #expect(try await client.download(
            exactDownload,
            to: destination
        ).fileURL == mockFileURL("exact-response"))

        do {
            _ = try await client.download(exactDownload, to: .temporary)
            Issue.record("Expected the type-wide download failure")
        } catch let error as MockTransferFixtureError {
            #expect(error == .typeDownload)
        }
    }

    @Test("Transfer failure stubs preserve structured HTTP failures unchanged")
    func structuredHTTPFailureStubs() async throws {
        let mock = MockAPIClient()
        let expected = HTTPFailure(
            metadata: HTTPResponseMetadata(
                statusCode: 503,
                url: URL(string: "https://api.example.com/maintenance"),
                headers: ["Retry-After": "120"]
            ),
            data: Data(#"{"message":"maintenance"}"#.utf8)
        )
        let error = NetworkError.requestFailed(expected)
        await mock.stubUploadError(
            MockTransferUploadRequest.self,
            error: error
        )
        await mock.stubDownloadError(
            MockTransferDownloadRequest.self,
            error: error
        )

        do {
            _ = try await mock.upload(
                MockTransferUploadRequest(
                    id: 1,
                    acceptedStatusCodes: .none
                ),
                from: .data(Data("upload".utf8))
            )
            Issue.record("Expected the upload HTTP failure")
        } catch let networkError as NetworkError {
            guard case .requestFailed(let failure) = networkError else {
                Issue.record("Expected requestFailed, got \(networkError)")
                return
            }
            #expect(failure == expected)
        }

        do {
            _ = try await mock.download(MockTransferDownloadRequest(
                id: 1,
                acceptedStatusCodes: .none
            ))
            Issue.record("Expected the download HTTP failure")
        } catch let networkError as NetworkError {
            guard case .requestFailed(let failure) = networkError else {
                Issue.record("Expected requestFailed, got \(networkError)")
                return
            }
            #expect(failure == expected)
        }
    }

    @Test("Successful transfer stubs enforce request status policies")
    func successfulTransferStatusPolicies() async throws {
        let mock = MockAPIClient()
        let uploadMetadata = HTTPResponseMetadata(
            statusCode: 409,
            url: URL(string: "https://api.example.com/uploads/conflict"),
            headers: ["X-Request-ID": "mock-upload"]
        )
        let uploadBody = Data("upload-conflict".utf8)
        await mock.stubUpload(
            MockTransferUploadRequest.self,
            with: HTTPResponse(
                value: MockTransferValue(id: 9),
                data: uploadBody,
                metadata: uploadMetadata
            )
        )
        let downloadMetadata = HTTPResponseMetadata(
            statusCode: 304,
            url: URL(string: "https://api.example.com/downloads/not-modified"),
            headers: ["ETag": "fixture"]
        )
        await mock.stubDownload(
            MockTransferDownloadRequest.self,
            with: DownloadResponse(
                fileURL: mockFileURL("not-modified"),
                metadata: downloadMetadata
            )
        )

        let upload = try await mock.upload(
            MockTransferUploadRequest(
                id: 1,
                acceptedStatusCodes: .codes([409])
            ),
            from: .data(Data("payload".utf8))
        )
        let download = try await mock.download(
            MockTransferDownloadRequest(
                id: 1,
                acceptedStatusCodes: .codes([304])
            )
        )

        #expect(upload.metadata == uploadMetadata)
        #expect(download.metadata == downloadMetadata)

        do {
            _ = try await mock.upload(
                MockTransferUploadRequest(id: 2),
                from: .data(Data("payload".utf8))
            )
            Issue.record("Expected the mock upload status rejection")
        } catch let error as NetworkError {
            guard case .requestFailed(let failure) = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
            #expect(failure == HTTPFailure(
                metadata: uploadMetadata,
                data: uploadBody
            ))
        }

        do {
            _ = try await mock.download(MockTransferDownloadRequest(id: 2))
            Issue.record("Expected the mock download status rejection")
        } catch let error as NetworkError {
            guard case .requestFailed(let failure) = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
            #expect(failure == HTTPFailure(
                metadata: downloadMetadata,
                data: nil
            ))
        }
    }

    @Test("Data and file uploads mirror body construction without file I/O")
    func uploadBodyConstruction() async throws {
        let mock = MockAPIClient(globalHeaders: ["X-Global": "global"])
        let dataRequest = MockTransferUploadRequest(id: 10)
        let fileRequest = MockTransferUploadRequest(id: 11)
        let data = Data([0x00, 0x01, 0x02])
        let missingFile = mockFileURL("never-created-upload")

        try await mock.stubUpload(
            dataRequest,
            from: .data(data),
            with: uploadResponse(id: 10)
        )
        try await mock.stubUpload(
            fileRequest,
            from: .file(missingFile),
            with: uploadResponse(id: 11)
        )

        _ = try await mock.upload(dataRequest, from: .data(data))
        _ = try await mock.upload(fileRequest, from: .file(missingFile))

        let records = await mock.recordedTransfers
        #expect(records.count == 2)
        #expect(records[0].operation == .upload(.data(data)))
        #expect(records[0].requestBody == data)
        #expect(records[0].headers["x-visible-body"] == "3")
        #expect(records[0].headers["x-global"] == "global")
        #expect(records[1].operation == .upload(.file(missingFile)))
        #expect(records[1].requestBody == nil)
        #expect(records[1].headers["x-visible-body"] == "file-backed")
    }

    @Test("Exact transfer arguments distinguish sources and destinations")
    func exactArgumentMatchingAndFileURLValidation() async throws {
        let mock = MockAPIClient()
        let uploadRequest = MockTransferUploadRequest(id: 12)
        let firstFile = mockFileURL("first-source")
        let secondFile = mockFileURL("second-source")
        try await mock.stubUpload(
            uploadRequest,
            from: .file(firstFile),
            with: uploadResponse(id: 1)
        )
        try await mock.stubUpload(
            uploadRequest,
            from: .file(secondFile),
            with: uploadResponse(id: 2)
        )

        #expect(try await mock.upload(
            MockTransferUploadRequest(
                id: uploadRequest.id,
                acceptedStatusCodes: .codes([201])
            ),
            from: .file(firstFile)
        ).value.id == 1)
        #expect(try await mock.upload(
            uploadRequest,
            from: .file(secondFile)
        ).value.id == 2)

        let downloadRequest = MockTransferDownloadRequest(id: 12)
        let destination = mockFileURL("destination")
        try await mock.stubDownload(
            downloadRequest,
            to: .temporary,
            with: downloadResponse("temporary")
        )
        try await mock.stubDownload(
            downloadRequest,
            to: .file(destination, overwriteExisting: false),
            with: downloadResponse("preserve")
        )
        try await mock.stubDownload(
            downloadRequest,
            to: .file(destination, overwriteExisting: true),
            with: downloadResponse("overwrite")
        )

        #expect(try await mock.download(
            MockTransferDownloadRequest(
                id: downloadRequest.id,
                acceptedStatusCodes: .codes([200])
            ),
            to: .temporary
        ).fileURL == mockFileURL("temporary"))
        #expect(try await mock.download(
            downloadRequest,
            to: .file(destination, overwriteExisting: false)
        ).fileURL == mockFileURL("preserve"))
        #expect(try await mock.download(
            downloadRequest,
            to: .file(destination, overwriteExisting: true)
        ).fileURL == mockFileURL("overwrite"))

        let recordCount = await mock.recordedTransfers.count
        let remoteURL = try #require(URL(string: "https://example.com/file"))
        await expectFileTransferError(.sourceIsNotFileURL(remoteURL)) {
            _ = try await mock.upload(uploadRequest, from: .file(remoteURL))
        }
        await expectFileTransferError(.destinationIsNotFileURL(remoteURL)) {
            _ = try await mock.download(
                downloadRequest,
                to: .file(remoteURL, overwriteExisting: false)
            )
        }
        #expect(await mock.recordedTransfers.count == recordCount)
    }

    @Test("Download factories create independent responses and see records")
    func downloadFactories() async throws {
        let factoryRecords = LockedBox<[RecordedTransfer]>([])
        let mock = MockAPIClient()
        await mock.stubDownload(MockTransferDownloadRequest.self) { record in
            let index = factoryRecords.withLock { records in
                records.append(record)
                return records.count
            }
            return DownloadResponse(
                fileURL: mockFileURL("factory-\(index)"),
                metadata: HTTPResponseMetadata(
                    statusCode: 200 + index,
                    url: record.url
                )
            )
        }

        let first = try await mock.download(MockTransferDownloadRequest(id: 1))
        let second = try await mock.download(MockTransferDownloadRequest(
            id: 2,
            acceptedStatusCodes: .codes([202])
        ))

        do {
            _ = try await mock.download(MockTransferDownloadRequest(
                id: 3,
                acceptedStatusCodes: .codes([204])
            ))
            Issue.record("Expected the factory response status rejection")
        } catch let error as NetworkError {
            guard case .requestFailed(let failure) = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
            #expect(failure.statusCode == 203)
            #expect(failure.data == nil)
        }

        #expect(first.fileURL == mockFileURL("factory-1"))
        #expect(second.fileURL == mockFileURL("factory-2"))
        #expect(first.statusCode == 201)
        #expect(second.statusCode == 202)
        #expect(factoryRecords.withLock { $0.map(\.sequenceID) } == [0, 1, 2])
        let records = await mock.recordedTransfers
        #expect(records.map(\.requestBody) == [
            Data("request-1".utf8),
            Data("request-2".utf8),
            Data("request-3".utf8)
        ])
        #expect(records.map { $0.headers["x-transfer"] } == [
            "download", "download", "download"
        ])
        #expect(records.map { $0.queryItems.first?.value } == ["1", "2", "3"])
    }

    @Test("Missing stubs include records and reset clears transfer state")
    func missingStubsAndReset() async throws {
        let mock = MockAPIClient()
        let uploadRequest = MockTransferUploadRequest(id: 20)
        let body = UploadBody.data(Data("missing".utf8))

        do {
            _ = try await mock.upload(uploadRequest, from: body)
            Issue.record("Expected a missing upload stub")
        } catch let error as MockTransferError {
            guard case .missingStub(let record) = error else {
                Issue.record("Expected missingStub, got \(error)")
                return
            }
            #expect(record.sequenceID == 0)
            #expect(record.operation == .upload(body))
            #expect(record.path == uploadRequest.path)
        }

        do {
            _ = try await mock.download(MockTransferDownloadRequest(id: 21))
            Issue.record("Expected a missing download stub")
        } catch let error as MockTransferError {
            guard case .missingStub(let record) = error else {
                Issue.record("Expected missingStub, got \(error)")
                return
            }
            #expect(record.sequenceID == 1)
            #expect(record.operation == .download(.temporary))
        }

        await mock.stubUpload(
            MockTransferUploadRequest.self,
            with: uploadResponse(id: 99)
        )
        await mock.clearRecordedTransfers()
        #expect(await mock.recordedTransfers.isEmpty)
        #expect(try await mock.upload(
            uploadRequest,
            from: body
        ).value.id == 99)
        #expect(await mock.recordedTransfers.map(\.sequenceID) == [2])

        await mock.setDelay(30)
        await mock.reset()

        #expect(await mock.recordedTransfers.isEmpty)
        do {
            _ = try await mock.upload(uploadRequest, from: body)
            Issue.record("Expected reset to clear transfer stubs")
        } catch let error as MockTransferError {
            guard case .missingStub(let record) = error else {
                Issue.record("Expected missingStub after reset, got \(error)")
                return
            }
            #expect(record.sequenceID == 3)
            #expect(error.localizedDescription.contains("upload"))
        }
    }

    @Test("Transfer construction failures stay typed and record nothing")
    func constructionFailures() async throws {
        let mock = MockAPIClient()
        let response = downloadResponse("unused")
        let cases: [
            (MockTransferConstructionBehavior, ExpectedConstructionFailure)
        ] = [
            (.invalidURL, .invalidURL),
            (.encodingFailure, .encoding),
            (.customizationFailure, .customization),
            (.customizationCancellation, .cancellation)
        ]

        for (behavior, expected) in cases {
            let request = MockTransferConstructionRequest(behavior: behavior)
            await expectConstructionFailure(expected) {
                _ = try await mock.download(request)
            }
            await expectConstructionFailure(expected) {
                try await mock.stubDownload(
                    request,
                    to: .temporary,
                    with: response
                )
            }
        }

        #expect(await mock.recordedTransfers.isEmpty)
    }

    @Test("Transfer delay cancellation is deterministic")
    func cancellation() async throws {
        let preCancelled = MockAPIClient()
        await preCancelled.stubUpload(
            MockTransferUploadRequest.self,
            with: uploadResponse(id: 29)
        )
        let preCancelledTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await preCancelled.upload(
                MockTransferUploadRequest(id: 29),
                from: .data(Data())
            )
        }
        do {
            _ = try await preCancelledTask.value
            Issue.record("Expected pre-cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await preCancelled.recordedTransfers.isEmpty)

        let started = AsyncSignal()
        let observedNanoseconds = LockedBox<UInt64?>(nil)
        let mock = MockAPIClient(
            delay: 2,
            sleeper: { nanoseconds in
                observedNanoseconds.withLock { $0 = nanoseconds }
                await started.signal()
                await AsyncSignal().wait()
                try Task.checkCancellation()
            }
        )
        await mock.stubUpload(
            MockTransferUploadRequest.self,
            with: uploadResponse(id: 30)
        )

        let task = Task {
            try await mock.upload(
                MockTransferUploadRequest(id: 30),
                from: .data(Data("payload".utf8))
            )
        }
        await started.wait()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected transfer cancellation")
        } catch {
            #expect(error is CancellationError)
        }

        #expect(observedNanoseconds.withLock { $0 } == 2_000_000_000)
        #expect(await mock.recordedTransfers.count == 1)

        let factoryStarted = AsyncSignal()
        let factoryMock = MockAPIClient()
        await factoryMock.stubDownload(
            MockTransferDownloadRequest.self,
            using: { _ in
                await factoryStarted.signal()
                await AsyncSignal().wait()
                return downloadResponse("cancelled-factory")
            }
        )
        let factoryTask = Task {
            try await factoryMock.download(
                MockTransferDownloadRequest(id: 31)
            )
        }
        await factoryStarted.wait()
        factoryTask.cancel()

        do {
            _ = try await factoryTask.value
            Issue.record("Expected factory cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("Concurrent transfers receive contiguous unique sequence IDs")
    func concurrentSequenceIDs() async throws {
        let mock = MockAPIClient()
        await mock.stubUpload(
            MockTransferUploadRequest.self,
            with: uploadResponse(id: 40)
        )
        await mock.stubDownload(
            MockTransferDownloadRequest.self,
            with: downloadResponse("concurrent")
        )
        let client: any APIClientTransferProtocol = mock
        let operationCount = 40

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<operationCount {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        _ = try await client.upload(
                            MockTransferUploadRequest(id: index),
                            from: .data(Data([UInt8(index)]))
                        )
                    } else {
                        _ = try await client.download(
                            MockTransferDownloadRequest(id: index)
                        )
                    }
                }
            }
            try await group.waitForAll()
        }

        let records = await mock.recordedTransfers
        #expect(records.map(\.sequenceID) == Array(0..<operationCount))
        #expect(Set(records.map(\.sequenceID)).count == operationCount)
        #expect(records.filter {
            if case .upload = $0.operation { return true }
            return false
        }.count == operationCount / 2)
        #expect(records.filter {
            if case .download = $0.operation { return true }
            return false
        }.count == operationCount / 2)
    }
}

private struct MockTransferValue: Codable, Equatable, Sendable {
    let id: Int
}

private enum MockTransferFixtureError: Error, Equatable, Sendable {
    case exactUpload
    case typeDownload
    case bodyEncodingMustBeBypassed
    case downloadEncoding
    case downloadCustomization
}

private struct MockTransferUploadRequest: Request {
    typealias ReturnType = MockTransferValue

    let id: Int
    let acceptedStatusCodes: HTTPStatusPolicy
    var path: String { "uploads/\(id)" }
    let method = HTTPMethod.post
    var queryItems: [URLQueryItem]? {
        [URLQueryItem(name: "id", value: String(id))]
    }
    var headers: [String: String]? {
        ["X-Request": String(id)]
    }

    init(
        id: Int,
        acceptedStatusCodes: HTTPStatusPolicy = .successful
    ) {
        self.id = id
        self.acceptedStatusCodes = acceptedStatusCodes
    }

    func makeBody(using encoder: JSONEncoder) throws -> Data? {
        throw MockTransferFixtureError.bodyEncodingMustBeBypassed
    }

    func customize(_ request: inout URLRequest) throws {
        let visibleBody = request.httpBody.map { String($0.count) }
            ?? "file-backed"
        request.setValue(visibleBody, forHTTPHeaderField: "X-Visible-Body")
    }
}

private struct MockTransferDownloadRequest: DownloadRequest {
    let id: Int
    let acceptedStatusCodes: HTTPStatusPolicy
    var path: String { "downloads/\(id)" }
    let method = HTTPMethod.post
    var queryItems: [URLQueryItem]? {
        [URLQueryItem(name: "id", value: String(id))]
    }
    var body: Data? { Data("request-\(id)".utf8) }

    init(
        id: Int,
        acceptedStatusCodes: HTTPStatusPolicy = .successful
    ) {
        self.id = id
        self.acceptedStatusCodes = acceptedStatusCodes
    }

    func customize(_ request: inout URLRequest) throws {
        request.setValue("download", forHTTPHeaderField: "X-Transfer")
    }
}

private enum MockTransferConstructionBehavior: Equatable, Sendable {
    case invalidURL
    case encodingFailure
    case customizationFailure
    case customizationCancellation
}

private struct MockTransferConstructionRequest: DownloadRequest {
    let behavior: MockTransferConstructionBehavior
    let path = "construction"

    func makeURL(baseURL: URL) -> URL? {
        guard behavior != .invalidURL else { return nil }
        return baseURL.appendingPathComponent(path)
    }

    func makeBody(using encoder: JSONEncoder) throws -> Data? {
        if behavior == .encodingFailure {
            throw MockTransferFixtureError.downloadEncoding
        }
        return Data("body".utf8)
    }

    func customize(_ request: inout URLRequest) throws {
        switch behavior {
        case .customizationFailure:
            throw MockTransferFixtureError.downloadCustomization
        case .customizationCancellation:
            throw CancellationError()
        case .invalidURL, .encodingFailure:
            break
        }
    }
}

private enum ExpectedConstructionFailure: Equatable {
    case invalidURL
    case encoding
    case customization
    case cancellation
}

private func uploadResponse(
    id: Int
) -> HTTPResponse<MockTransferValue> {
    HTTPResponse(
        value: MockTransferValue(id: id),
        metadata: HTTPResponseMetadata(statusCode: 200 + id)
    )
}

private func downloadResponse(_ name: String) -> DownloadResponse {
    DownloadResponse(
        fileURL: mockFileURL(name),
        metadata: HTTPResponseMetadata(statusCode: 200)
    )
}

private func mockFileURL(_ name: String) -> URL {
    URL(fileURLWithPath: "/mock-transfer-fixtures/\(name)")
}

private func expectFileTransferError(
    _ expected: FileTransferError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected file transfer error")
    } catch let error as NetworkError {
        guard case .fileOperationFailed(let underlying) = error,
              let transferError = underlying as? FileTransferError else {
            Issue.record("Expected fileOperationFailed, got \(error)")
            return
        }
        #expect(transferError == expected)
    } catch {
        Issue.record("Expected NetworkError, got \(error)")
    }
}

private func expectConstructionFailure(
    _ expected: ExpectedConstructionFailure,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected transfer construction failure")
    } catch is CancellationError {
        #expect(expected == .cancellation)
    } catch let error as NetworkError {
        switch (expected, error) {
        case (.invalidURL, .invalidURL):
            break
        case (.encoding, .encodingFailed(let underlying)):
            #expect(
                underlying as? MockTransferFixtureError == .downloadEncoding
            )
        case (.customization, .requestConfigurationFailed(let underlying)):
            #expect(
                underlying as? MockTransferFixtureError
                    == .downloadCustomization
            )
        default:
            Issue.record("Unexpected construction error: \(error)")
        }
    } catch {
        Issue.record("Unexpected construction error: \(error)")
    }
}
