import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK
import AnotherFuckingNetworkingSDKTesting

@Suite("HTTP retry transport")
struct RetryTransportTests {
    @Test("HTTP attempts honor Retry-After and remain one monitored operation")
    func httpRetriesAndMonitoring() async throws {
        let calls = LockedBox(0)
        let delays = LockedBox<[UInt64]>([])
        let logs = LockedBox<[String]>([])
        let successBody = userBody(id: 7, name: "Retried")
        let stub = StubSession { request in
            let attempt = calls.withLock { calls in
                calls += 1
                return calls
            }
            switch attempt {
            case 1:
                return .respond(try .http(
                    for: request,
                    statusCode: 503,
                    headers: ["Retry-After": "2"],
                    data: Data("first".utf8)
                ))
            case 2:
                return .respond(try .http(
                    for: request,
                    statusCode: 502,
                    data: Data("second".utf8)
                ))
            default:
                return .respond(try .http(for: request, data: successBody))
            }
        }
        let monitor = NetworkActivityMonitor()
        let logger = NetworkingLogger { _, message in
            logs.withLock { $0.append(message) }
        }
        let client = stub.client(
            logger: logger,
            activityMonitor: monitor,
            retrySleeper: { delay in
                delays.withLock { $0.append(delay) }
            },
            retryRandom: { 1 }
        )
        let request = RetryUserRequest(retryPolicy: .transient(
            maximumAttempts: 3,
            initialDelay: 0.1,
            maximumDelay: 5,
            multiplier: 2,
            jitter: .none
        ))

        let value = try await client.send(request)

        #expect(value == TestUser(id: 7, displayName: "Retried"))
        #expect(calls.withLock { $0 } == 3)
        #expect(delays.withLock { $0 } == [2_000_000_000, 200_000_000])
        let retryLogs = logs.withLock { messages in
            messages.filter { $0.hasPrefix("Scheduling HTTP retry attempt") }
        }
        #expect(retryLogs.count == 2)
        #expect(retryLogs[0].contains("attempt 2"))
        #expect(retryLogs[1].contains("attempt 3"))
        let snapshot = monitor.currentSnapshot
        #expect(snapshot.succeededCount == 1)
        #expect(snapshot.failedCount == 0)
        #expect(snapshot.totalActiveCount == 0)
        #expect(snapshot.revision == 2)
    }

    @Test("HTTP byte streams retry before exposing response bytes")
    func byteStreamRetriesBeforeExposure() async throws {
        let calls = LockedBox(0)
        let stub = StubSession { request in
            let attempt = calls.withLock { calls in
                calls += 1
                return calls
            }
            if attempt == 1 {
                return .respond(try .http(
                    for: request,
                    statusCode: 503,
                    data: Data("temporary".utf8)
                ))
            }
            return .respond(try .http(
                for: request,
                data: Data("streamed".utf8)
            ))
        }
        let client = stub.client(retrySleeper: { _ in })
        let request = RetryUserRequest(retryPolicy: .transient(
            maximumAttempts: 2,
            initialDelay: 0,
            jitter: .none
        ))

        let stream = try await client.stream(request)
        var received = Data()
        for try await byte in stream {
            received.append(byte)
        }

        #expect(received == Data("streamed".utf8))
        #expect(calls.withLock { $0 } == 2)
    }

    @Test("Pagination forwards retry policy across transport failures")
    func paginatedTransportRetry() async throws {
        let calls = LockedBox(0)
        let pageBody = Data(
            #"{"items":[{"id":4,"displayName":"Page"}],"currentPage":1,"totalPages":1}"#.utf8
        )
        let stub = StubSession { request in
            let attempt = calls.withLock { calls in
                calls += 1
                return calls
            }
            if attempt == 1 {
                return .fail(URLError(.networkConnectionLost))
            }
            return .respond(try .http(for: request, data: pageBody))
        }
        let client = stub.client(retrySleeper: { _ in })

        let page = try await client.sendPage(RetryPageRequest(
            retryPolicy: .transient(
                maximumAttempts: 2,
                initialDelay: 0,
                jitter: .none
            )
        ))

        #expect(page.items == [TestUser(id: 4, displayName: "Page")])
        #expect(calls.withLock { $0 } == 2)
    }

    @Test("Accepted statuses win and exhaustion preserves the final HTTP failure")
    func acceptedStatusAndExhaustion() async throws {
        let acceptedCalls = LockedBox(0)
        let acceptedStub = StubSession { request in
            acceptedCalls.withLock { $0 += 1 }
            return .respond(try .http(
                for: request,
                statusCode: 503,
                data: userBody(id: 5, name: "Accepted")
            ))
        }
        let accepted = try await acceptedStub.client().send(
            RetryUserRequest(
                retryPolicy: .transient(maximumAttempts: 3),
                acceptedStatusCodes: .codes([503])
            )
        )
        #expect(accepted == TestUser(id: 5, displayName: "Accepted"))
        #expect(acceptedCalls.withLock { $0 } == 1)

        let exhaustedCalls = LockedBox(0)
        let exhaustedStub = StubSession { request in
            let attempt = exhaustedCalls.withLock { calls in
                calls += 1
                return calls
            }
            return .respond(try .http(
                for: request,
                statusCode: 503,
                headers: ["X-Attempt": String(attempt)],
                data: Data("attempt-\(attempt)".utf8)
            ))
        }
        do {
            _ = try await exhaustedStub.client(
                retrySleeper: { _ in }
            ).send(RetryUserRequest(retryPolicy: .transient(
                maximumAttempts: 3,
                initialDelay: 0,
                jitter: .none
            )))
            Issue.record("Expected retry exhaustion")
        } catch let error as NetworkError {
            guard case .requestFailed(let failure) = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
            #expect(failure.statusCode == 503)
            #expect(failure.data == Data("attempt-3".utf8))
            #expect(failure.value(forHTTPHeaderField: "X-Attempt") == "3")
        }
        #expect(exhaustedCalls.withLock { $0 } == 3)
    }

    @Test("Non-idempotent and customized methods require explicit replay safety")
    func replaySafetyUsesFinalMethod() async throws {
        let postCalls = LockedBox(0)
        let postStub = StubSession { request in
            postCalls.withLock { $0 += 1 }
            return .respond(try .http(for: request, statusCode: 503))
        }
        do {
            _ = try await postStub.client().send(RetryUserRequest(
                method: .post,
                retryPolicy: .transient(maximumAttempts: 3)
            ))
            Issue.record("Expected POST not to replay")
        } catch let error as NetworkError {
            guard case .requestFailed = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
        }
        #expect(postCalls.withLock { $0 } == 1)

        let customizedCalls = LockedBox(0)
        let customizedStub = StubSession { request in
            customizedCalls.withLock { $0 += 1 }
            return .respond(try .http(for: request, statusCode: 503))
        }
        do {
            _ = try await customizedStub.client().send(RetryUserRequest(
                method: .get,
                retryPolicy: .transient(maximumAttempts: 3),
                customizedMethod: "POST"
            ))
            Issue.record("Expected the final POST method not to replay")
        } catch let error as NetworkError {
            guard case .requestFailed = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
        }
        #expect(customizedCalls.withLock { $0 } == 1)

        let explicitCalls = LockedBox(0)
        let explicitStub = StubSession { request in
            let attempt = explicitCalls.withLock { calls in
                calls += 1
                return calls
            }
            if attempt == 1 {
                return .respond(try .http(for: request, statusCode: 503))
            }
            return .respond(try .http(
                for: request,
                data: userBody(id: 6, name: "Idempotent")
            ))
        }
        let explicit = try await explicitStub.client(
            retrySleeper: { _ in }
        ).send(RetryUserRequest(
            method: .post,
            retryPolicy: .transient(
                maximumAttempts: 2,
                initialDelay: 0,
                jitter: .none,
                replaySafety: .explicitlyReplayable
            )
        ))
        #expect(explicit == TestUser(id: 6, displayName: "Idempotent"))
        #expect(explicitCalls.withLock { $0 } == 2)
    }

    @Test("Retry policy is captured once before the first transport suspension")
    func policySnapshot() async throws {
        let state = LockedBox((
            reads: 0,
            policy: HTTPRetryPolicy.transient(
                maximumAttempts: 2,
                initialDelay: 0,
                jitter: .none
            )
        ))
        let calls = LockedBox(0)
        let stub = StubSession { request in
            let attempt = calls.withLock { calls in
                calls += 1
                return calls
            }
            state.withLock { $0.policy = .never }
            if attempt == 1 {
                return .respond(try .http(for: request, statusCode: 503))
            }
            return .respond(try .http(
                for: request,
                data: userBody(id: 8, name: "Snapshot")
            ))
        }

        let value = try await stub.client(
            retrySleeper: { _ in }
        ).send(SnapshotRetryRequest(state: state))

        #expect(value == TestUser(id: 8, displayName: "Snapshot"))
        #expect(calls.withLock { $0 } == 2)
        #expect(state.withLock { $0.reads } == 1)
    }

    @Test("Cancellation wins when an injected sleeper ignores cancellation")
    func cancellationDuringBackoff() async throws {
        let calls = LockedBox(0)
        let sleeperStarted = AsyncSignal()
        let stub = StubSession { request in
            calls.withLock { $0 += 1 }
            return .respond(try .http(for: request, statusCode: 503))
        }
        let client = stub.client(retrySleeper: { _ in
            await sleeperStarted.signal()
            while !Task.isCancelled {
                await Task.yield()
            }
        })
        let task = Task {
            try await client.send(RetryUserRequest(retryPolicy: .transient(
                maximumAttempts: 3,
                initialDelay: 1,
                jitter: .none
            )))
        }

        guard await sleeperStarted.wait() else {
            task.cancel()
            _ = try? await task.value
            return
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation during retry backoff")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("Cancellation during a terminal retry decision wins")
    func cancellationDuringTerminalDecision() async throws {
        let responseCalls = LockedBox(0)
        let responseStub = StubSession { request in
            responseCalls.withLock { $0 += 1 }
            return .respond(try .http(for: request, statusCode: 418))
        }
        let responseTask = Task {
            try await responseStub.client(retryNow: cancellingNow).send(
                RetryUserRequest(retryPolicy: .transient(maximumAttempts: 2))
            )
        }

        do {
            _ = try await responseTask.value
            Issue.record("Expected cancellation during the response decision")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(responseCalls.withLock { $0 } == 1)

        let downloadStub = StubSession { _ in
            .pending(onStart: {}, onStop: {})
        }
        let downloadTask = Task {
            try await downloadStub.client(
                downloadOperation: { _ in
                    throw URLError(.badServerResponse)
                },
                retryNow: cancellingNow
            ).download(RetryDownloadRequest())
        }

        do {
            _ = try await downloadTask.value
            Issue.record("Expected cancellation during the download decision")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("Cancellation inside transport never becomes a retry")
    func cancellationInsideTransport() async throws {
        let calls = LockedBox(0)
        let started = AsyncSignal()
        let stopped = AsyncSignal()
        let stub = StubSession { _ in
            calls.withLock { $0 += 1 }
            return .pending(
                onStart: { Task { await started.signal() } },
                onStop: { Task { await stopped.signal() } }
            )
        }
        let task = Task {
            try await stub.client().send(RetryUserRequest(
                retryPolicy: .transient(
                    maximumAttempts: 3,
                    initialDelay: 0,
                    jitter: .none
                )
            ))
        }

        guard await started.wait() else {
            task.cancel()
            _ = try? await task.value
            return
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected transport cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        guard await stopped.wait() else { return }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("Data and stable file uploads replay their supplied bodies")
    func uploadRetries() async throws {
        let responseBody = userBody(id: 9, name: "Uploaded")
        let dataCalls = LockedBox(0)
        let dataBodies = LockedBox<[Data?]>([])
        let dataStub = StubSession { request in
            dataBodies.withLock { $0.append(requestBodyData(request)) }
            let attempt = dataCalls.withLock { calls in
                calls += 1
                return calls
            }
            if attempt == 1 {
                return .respond(try .http(for: request, statusCode: 503))
            }
            return .respond(try .http(for: request, data: responseBody))
        }
        let payload = Data("data-upload".utf8)
        let dataResponse = try await dataStub.client(
            retrySleeper: { _ in }
        ).upload(
            RetryUploadRequest(),
            from: .data(payload)
        )
        #expect(dataResponse.value == TestUser(id: 9, displayName: "Uploaded"))
        #expect(dataCalls.withLock { $0 } == 2)
        #expect(dataBodies.withLock { $0 } == [payload, payload])

        let fileURL = retryTemporaryURL()
        let filePayload = Data("file-upload".utf8)
        try filePayload.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let fileCalls = LockedBox(0)
        let fileBodies = LockedBox<[Data?]>([])
        let fileStub = StubSession { request in
            fileBodies.withLock { $0.append(requestBodyData(request)) }
            let attempt = fileCalls.withLock { calls in
                calls += 1
                return calls
            }
            if attempt == 1 {
                return .fail(URLError(.networkConnectionLost))
            }
            return .respond(try .http(for: request, data: responseBody))
        }
        let fileResponse = try await fileStub.client(
            retrySleeper: { _ in }
        ).upload(
            RetryUploadRequest(),
            from: .file(fileURL)
        )
        #expect(fileResponse.value == TestUser(id: 9, displayName: "Uploaded"))
        #expect(fileCalls.withLock { $0 } == 2)
        #expect(fileBodies.withLock { $0 } == [filePayload, filePayload])
    }

    @Test("File uploads revalidate their source before replay")
    func fileUploadRevalidation() async throws {
        let sourceURL = retryTemporaryURL()
        try Data("remove-before-retry".utf8).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let calls = LockedBox(0)
        let stub = StubSession { request in
            calls.withLock { $0 += 1 }
            return .respond(try .http(for: request, statusCode: 503))
        }
        let client = stub.client(retrySleeper: { _ in
            try FileManager.default.removeItem(at: sourceURL)
        })

        do {
            _ = try await client.upload(
                RetryUploadRequest(retryPolicy: .transient(
                    maximumAttempts: 2,
                    initialDelay: 0.001,
                    jitter: .none
                )),
                from: .file(sourceURL)
            )
            Issue.record("Expected the removed source to stop replay")
        } catch let error as NetworkError {
            guard case .fileOperationFailed(let underlying) = error,
                  underlying as? FileTransferError
                    == .sourceDoesNotExist(sourceURL) else {
                Issue.record("Expected sourceDoesNotExist, got \(error)")
                return
            }
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("Retried downloads discard each abandoned temporary file")
    func downloadRetryCleanup() async throws {
        let firstURL = retryTemporaryURL()
        let secondURL = retryTemporaryURL()
        try Data("first-attempt".utf8).write(to: firstURL)
        try Data("completed".utf8).write(to: secondURL)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let calls = LockedBox(0)
        let stub = StubSession { _ in
            .pending(onStart: {}, onStop: {})
        }
        let client = stub.client(
            downloadOperation: { request in
                let attempt = calls.withLock { calls in
                    calls += 1
                    return calls
                }
                let url = attempt == 1 ? firstURL : secondURL
                let status = attempt == 1 ? 503 : 200
                return (
                    url,
                    try StubURLProtocol.StubResponse.http(
                        for: request,
                        statusCode: status
                    ).response
                )
            },
            retrySleeper: { _ in }
        )

        let response = try await client.download(RetryDownloadRequest())
        defer { try? FileManager.default.removeItem(at: response.fileURL) }

        #expect(calls.withLock { $0 } == 2)
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
        #expect(!FileManager.default.fileExists(atPath: secondURL.path))
        #expect(try Data(contentsOf: response.fileURL) == Data("completed".utf8))
    }

    @Test("Download cancellation during backoff follows temporary cleanup")
    func downloadBackoffCancellation() async throws {
        let temporaryURL = retryTemporaryURL()
        try Data("abandoned".utf8).write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let calls = LockedBox(0)
        let sleeperStarted = AsyncSignal()
        let stub = StubSession { _ in
            .pending(onStart: {}, onStop: {})
        }
        let client = stub.client(
            downloadOperation: { request in
                calls.withLock { $0 += 1 }
                return (
                    temporaryURL,
                    try StubURLProtocol.StubResponse.http(
                        for: request,
                        statusCode: 503
                    ).response
                )
            },
            retrySleeper: { _ in
                await sleeperStarted.signal()
                while !Task.isCancelled {
                    await Task.yield()
                }
            }
        )
        let task = Task {
            try await client.download(RetryDownloadRequest(retryPolicy: .transient(
                maximumAttempts: 3,
                initialDelay: 1,
                jitter: .none
            )))
        }

        guard await sleeperStarted.wait() else {
            task.cancel()
            _ = try? await task.value
            return
        }
        #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation during download backoff")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("Exhausted downloads preserve only the final bounded failure body")
    func downloadExhaustion() async throws {
        let urls = (0..<3).map { _ in retryTemporaryURL() }
        let bodies = ["first", "second", "final"].map { Data($0.utf8) }
        for (url, body) in zip(urls, bodies) {
            try body.write(to: url)
        }
        defer {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let calls = LockedBox(0)
        let stub = StubSession { _ in
            .pending(onStart: {}, onStop: {})
        }
        let statuses = [503, 502, 429]
        let client = stub.client(
            downloadOperation: { request in
                let index = calls.withLock { calls in
                    defer { calls += 1 }
                    return calls
                }
                return (
                    urls[index],
                    try StubURLProtocol.StubResponse.http(
                        for: request,
                        statusCode: statuses[index],
                        headers: ["X-Attempt": String(index + 1)]
                    ).response
                )
            },
            retrySleeper: { _ in }
        )

        do {
            _ = try await client.download(RetryDownloadRequest())
            Issue.record("Expected download retry exhaustion")
        } catch let error as NetworkError {
            guard case .requestFailed(let failure) = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
            #expect(failure.statusCode == 429)
            #expect(failure.data == bodies[2])
            #expect(failure.value(forHTTPHeaderField: "X-Attempt") == "3")
        }
        #expect(calls.withLock { $0 } == 3)
        #expect(urls.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
    }

    @Test("Non-transient transport and decoding failures never replay")
    func nonRetryableFailures() async throws {
        let transportCalls = LockedBox(0)
        let transportStub = StubSession { _ in
            transportCalls.withLock { $0 += 1 }
            return .fail(URLError(.badServerResponse))
        }
        do {
            _ = try await transportStub.client().send(RetryUserRequest(
                retryPolicy: .transient(maximumAttempts: 3)
            ))
            Issue.record("Expected a non-transient transport failure")
        } catch let error as NetworkError {
            guard case .transport(let underlying) = error else {
                Issue.record("Expected transport, got \(error)")
                return
            }
            #expect(underlying.code == .badServerResponse)
        }
        #expect(transportCalls.withLock { $0 } == 1)

        let decodingCalls = LockedBox(0)
        let decodingStub = StubSession { request in
            decodingCalls.withLock { $0 += 1 }
            return .respond(try .http(
                for: request,
                data: Data("not-json".utf8)
            ))
        }
        do {
            _ = try await decodingStub.client().send(RetryUserRequest(
                retryPolicy: .transient(maximumAttempts: 3)
            ))
            Issue.record("Expected a decoding failure")
        } catch let error as NetworkError {
            guard case .decodingFailed = error else {
                Issue.record("Expected decodingFailed, got \(error)")
                return
            }
        }
        #expect(decodingCalls.withLock { $0 } == 1)
    }

    @Test("Logical mocks ignore retry execution and retry policy wire identity")
    func logicalMockBehavior() async throws {
        let exactMock = MockAPIClient()
        let exactRequest = RetryUserRequest(retryPolicy: .never)
        try await exactMock.stub(
            exactRequest,
            with: TestUser(id: 10, displayName: "Mock")
        )
        let value = try await exactMock.send(RetryUserRequest(
            retryPolicy: .transient(maximumAttempts: 3)
        ))
        #expect(value == TestUser(id: 10, displayName: "Mock"))
        #expect(await exactMock.recordedRequests.count == 1)

        let failureMock = MockAPIClient()
        await failureMock.stubError(
            RetryUserRequest.self,
            error: RetryFixtureError.expected
        )
        do {
            _ = try await failureMock.send(RetryUserRequest(
                retryPolicy: .transient(
                    maximumAttempts: 3,
                    replaySafety: .explicitlyReplayable
                )
            ))
            Issue.record("Expected the explicit mock failure")
        } catch let error as RetryFixtureError {
            #expect(error == .expected)
        }
        #expect(await failureMock.recordedRequests.count == 1)
    }
}

private struct RetryUserRequest: Request {
    typealias ReturnType = TestUser

    let path: String
    let method: HTTPMethod
    let retryPolicy: HTTPRetryPolicy
    let acceptedStatusCodes: HTTPStatusPolicy
    let customizedMethod: String?

    init(
        path: String = "retry/user",
        method: HTTPMethod = .get,
        retryPolicy: HTTPRetryPolicy,
        acceptedStatusCodes: HTTPStatusPolicy = .successful,
        customizedMethod: String? = nil
    ) {
        self.path = path
        self.method = method
        self.retryPolicy = retryPolicy
        self.acceptedStatusCodes = acceptedStatusCodes
        self.customizedMethod = customizedMethod
    }

    func customize(_ urlRequest: inout URLRequest) throws {
        if let customizedMethod {
            urlRequest.httpMethod = customizedMethod
        }
    }
}

private struct SnapshotRetryRequest: Request {
    typealias ReturnType = TestUser

    let state: LockedBox<(reads: Int, policy: HTTPRetryPolicy)>
    let path = "retry/snapshot"

    var retryPolicy: HTTPRetryPolicy {
        state.withLock { state in
            state.reads += 1
            return state.policy
        }
    }
}

private struct RetryPageRequest: PaginatedRequest {
    typealias ReturnType = TestUser

    let retryPolicy: HTTPRetryPolicy
    let path = "retry/page"
    let page = 1
    let pageSize = 20
}

private struct RetryUploadRequest: Request {
    typealias ReturnType = TestUser

    let path = "retry/upload"
    let method = HTTPMethod.put
    let retryPolicy: HTTPRetryPolicy

    init(
        retryPolicy: HTTPRetryPolicy = .transient(
            maximumAttempts: 2,
            initialDelay: 0,
            jitter: .none
        )
    ) {
        self.retryPolicy = retryPolicy
    }
}

private struct RetryDownloadRequest: DownloadRequest {
    let path = "retry/download"
    let retryPolicy: HTTPRetryPolicy

    init(
        retryPolicy: HTTPRetryPolicy = .transient(
            maximumAttempts: 3,
            initialDelay: 0,
            jitter: .none
        )
    ) {
        self.retryPolicy = retryPolicy
    }
}

private enum RetryFixtureError: Error, Equatable, Sendable {
    case expected
}

private func userBody(id: Int, name: String) -> Data {
    Data(#"{"id":\#(id),"displayName":"\#(name)"}"#.utf8)
}

private func retryTemporaryURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "afnsdk-retry-\(UUID().uuidString)",
        isDirectory: false
    )
}

private func cancellingNow() -> Date {
    withUnsafeCurrentTask { task in
        task?.cancel()
    }
    return Date()
}
