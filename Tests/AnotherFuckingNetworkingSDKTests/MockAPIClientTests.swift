import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK
@testable import AnotherFuckingNetworkingSDKTesting

@Suite("MockAPIClient")
struct MockAPIClientTests {
    @Test("Type-wide successful stubs support protocol-based injection")
    func typeStubAndInjection() async throws {
        let mock = MockAPIClient()
        let expected = TestUser(id: 42, displayName: "Arthur")
        await mock.stub(GetUserRequest.self, with: expected)
        let service = MockUserService(client: mock)

        let value = try await service.user(id: 42)

        #expect(value == expected)
    }

    @Test("Exact success overrides a type-wide error")
    func exactSuccessPrecedence() async throws {
        let mock = MockAPIClient()
        let exactRequest = GetUserRequest(id: 1)
        let expected = TestUser(id: 1, displayName: "Exact")
        await mock.stubError(GetUserRequest.self, error: MockFixtureError.typeDefault)
        try await mock.stub(exactRequest, with: expected)

        #expect(try await mock.send(exactRequest) == expected)

        do {
            _ = try await mock.send(GetUserRequest(id: 2))
            Issue.record("Expected the type-wide failure")
        } catch let error as MockFixtureError {
            #expect(error == .typeDefault)
        }
    }

    @Test("Exact error overrides a type-wide success")
    func exactFailurePrecedence() async throws {
        let mock = MockAPIClient()
        let exactRequest = GetUserRequest(id: 1)
        await mock.stub(
            GetUserRequest.self,
            with: TestUser(id: 0, displayName: "Default")
        )
        try await mock.stubError(exactRequest, error: MockFixtureError.exact)

        do {
            _ = try await mock.send(exactRequest)
            Issue.record("Expected the exact failure")
        } catch let error as MockFixtureError {
            #expect(error == .exact)
        }
    }

    @Test("The latest registration at the same scope wins")
    func latestRegistrationWins() async throws {
        let mock = MockAPIClient()
        await mock.stub(
            GetUserRequest.self,
            with: TestUser(id: 1, displayName: "First")
        )
        let expected = TestUser(id: 2, displayName: "Second")
        await mock.stub(GetUserRequest.self, with: expected)

        #expect(try await mock.send(GetUserRequest(id: 99)) == expected)
    }

    @Test("Page stubs are strongly typed and separate from ordinary stubs")
    func pageStubs() async throws {
        let mock = MockAPIClient()
        let request = MockPageRequest(page: 1, pageSize: 20, filter: "active")
        let expected = PaginatedResponse(
            items: [TestUser(id: 1, displayName: "Page")],
            currentPage: 1,
            totalPages: 2
        )
        await mock.stubPage(MockPageRequest.self, with: expected)

        #expect(try await mock.sendPage(request) == expected)

        do {
            _ = try await mock.send(request)
            Issue.record("A page stub must not satisfy a normal send")
        } catch let error as MockAPIClientError {
            guard case .missingStub(let invocation) = error else {
                Issue.record("Expected missingStub, got \(error)")
                return
            }
            #expect(invocation.operation == .request)
        }
    }

    @Test("Paginated failures propagate unchanged")
    func pageFailure() async throws {
        let mock = MockAPIClient()
        await mock.stubPageError(
            MockPageRequest.self,
            error: MockFixtureError.typeDefault
        )

        do {
            _ = try await mock.sendPage(
                MockPageRequest(page: 1, pageSize: 20, filter: "active")
            )
            Issue.record("Expected the paginated error")
        } catch let error as MockFixtureError {
            #expect(error == .typeDefault)
        }
    }

    @Test("Exact page stubs distinguish pagination and filters")
    func exactPageMatching() async throws {
        let mock = MockAPIClient()
        let fallback = PaginatedResponse<TestUser>(
            items: [],
            currentPage: 0,
            totalPages: 0
        )
        let exactRequest = MockPageRequest(page: 2, pageSize: 10, filter: "active")
        let exact = PaginatedResponse(
            items: [TestUser(id: 2, displayName: "Exact Page")],
            currentPage: 2,
            totalPages: 4
        )
        await mock.stubPage(MockPageRequest.self, with: fallback)
        try await mock.stubPage(exactRequest, with: exact)

        #expect(try await mock.sendPage(exactRequest) == exact)
        #expect(try await mock.sendPage(
            MockPageRequest(page: 3, pageSize: 10, filter: "active")
        ) == fallback)
        #expect(try await mock.sendPage(
            MockPageRequest(page: 2, pageSize: 10, filter: "archived")
        ) == fallback)
    }

    @Test("Missing ordinary and page stubs both throw diagnostic errors")
    func missingStubs() async throws {
        let mock = MockAPIClient()

        do {
            _ = try await mock.send(GetUserRequest(id: 404))
            Issue.record("Expected a missing request stub")
        } catch let error as MockAPIClientError {
            guard case .missingStub(let request) = error else {
                Issue.record("Expected missingStub, got \(error)")
                return
            }
            #expect(request.path == "users/404")
            #expect(request.operation == .request)
        }

        do {
            _ = try await mock.sendPage(
                MockPageRequest(page: 4, pageSize: 50, filter: "missing")
            )
            Issue.record("Expected a missing page stub")
        } catch let error as MockAPIClientError {
            guard case .missingStub(let request) = error else {
                Issue.record("Expected missingStub, got \(error)")
                return
            }
            #expect(request.operation == .page)
            #expect(request.page == 4)
            #expect(request.pageSize == 50)
        }
    }

    @Test("Invocations record structured request data and reset atomically")
    func recordingAndReset() async throws {
        let mock = MockAPIClient()
        let request = RecordingRequest()
        try await mock.stub(request, with: EmptyResponse())

        _ = try await mock.send(request)

        var records = await mock.recordedRequests
        let record = try #require(records.first)
        #expect(record.sequenceID == 0)
        #expect(record.operation == .request)
        #expect(record.requestTypeID == ObjectIdentifier(RecordingRequest.self))
        #expect(record.method == .post)
        #expect(record.url.absoluteString == "https://mock.invalid/record?q=value")
        #expect(record.path == "record")
        #expect(record.queryItems == [URLQueryItem(name: "q", value: "value")])
        #expect(record.headers == ["X-Test": "header"])
        #expect(record.body == Data("body".utf8))

        await mock.clearRecordedRequests()
        _ = try await mock.send(request)
        records = await mock.recordedRequests
        #expect(records.map(\.sequenceID) == [0])

        await mock.reset()
        #expect(await mock.recordedRequests.isEmpty)
        do {
            _ = try await mock.send(request)
            Issue.record("Reset should remove stubs")
        } catch is MockAPIClientError {
            // Expected.
        }
    }

    @Test("Exact stubs use bodies produced by the configured encoder")
    func encodedBodyMatching() async throws {
        let mock = MockAPIClient(encoderFactory: {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            return encoder
        })
        let first = EncodedBodyRequest(displayName: "Arthur")
        let second = EncodedBodyRequest(displayName: "Ford")
        let firstResponse = TestUser(id: 1, displayName: "First")
        let secondResponse = TestUser(id: 2, displayName: "Second")
        try await mock.stub(first, with: firstResponse)
        try await mock.stub(second, with: secondResponse)

        #expect(try await mock.send(first) == firstResponse)
        #expect(try await mock.send(second) == secondResponse)

        let bodies = await mock.recordedRequests.compactMap(\.body)
        let decodedBodies = try bodies.map {
            try JSONSerialization.jsonObject(with: $0) as? [String: String]
        }
        #expect(decodedBodies == [
            ["display_name": "Arthur"],
            ["display_name": "Ford"]
        ])
    }

    @Test("Exact stubs include custom final URLs")
    func customURLMatching() async throws {
        let baseURL = URL(string: "https://example.com/v1")!
        let mock = MockAPIClient(baseURL: baseURL)
        let first = CustomURLRequest(variant: "first")
        let second = CustomURLRequest(variant: "second")
        let firstResponse = TestUser(id: 1, displayName: "First")
        let secondResponse = TestUser(id: 2, displayName: "Second")
        try await mock.stub(first, with: firstResponse)
        try await mock.stub(second, with: secondResponse)

        #expect(try await mock.send(first) == firstResponse)
        #expect(try await mock.send(second) == secondResponse)
        #expect(await mock.recordedRequests.map(\.url.absoluteString) == [
            "https://example.com/v1/shared?variant=first",
            "https://example.com/v1/shared?variant=second"
        ])
    }

    @Test("Exact stubs preserve order-sensitive duplicate query items")
    func orderedQueryMatching() async throws {
        let mock = MockAPIClient()
        let first = OrderedQueryRequest(values: ["one", "two"])
        let second = OrderedQueryRequest(values: ["two", "one"])
        let firstResponse = TestUser(id: 1, displayName: "First")
        let secondResponse = TestUser(id: 2, displayName: "Second")
        try await mock.stub(first, with: firstResponse)
        try await mock.stub(second, with: secondResponse)

        #expect(try await mock.send(first) == firstResponse)
        #expect(try await mock.send(second) == secondResponse)
    }

    @Test("Injected delays are deterministic and do not use wall-clock sleeps")
    func injectedDelay() async throws {
        let capturedDelay = LockedBox<UInt64?>(nil)
        let mock = MockAPIClient(delay: 1.25) { nanoseconds in
            capturedDelay.withLock { $0 = nanoseconds }
        }
        await mock.stub(
            GetUserRequest.self,
            with: TestUser(id: 1, displayName: "Delayed")
        )

        _ = try await mock.send(GetUserRequest(id: 1))

        #expect(capturedDelay.withLock { $0 } == 1_250_000_000)
    }

    @Test("Delay conversion clamps huge values and ignores invalid values")
    func delayBoundaries() async throws {
        let capturedDelays = LockedBox<[UInt64]>([])
        let mock = MockAPIClient(delay: .greatestFiniteMagnitude) { nanoseconds in
            capturedDelays.withLock { $0.append(nanoseconds) }
        }
        await mock.stub(
            GetUserRequest.self,
            with: TestUser(id: 1, displayName: "Delayed")
        )

        _ = try await mock.send(GetUserRequest(id: 1))
        await mock.setDelay(.infinity)
        _ = try await mock.send(GetUserRequest(id: 2))
        await mock.setDelay(.nan)
        _ = try await mock.send(GetUserRequest(id: 3))
        await mock.setDelay(-1)
        _ = try await mock.send(GetUserRequest(id: 4))

        #expect(capturedDelays.withLock { $0 } == [UInt64.max])
    }

    @Test("A pre-cancelled mock send never attempts body encoding")
    func cancellationBeforeEncoding() async throws {
        let gate = AsyncSignal()
        let mock = MockAPIClient()
        await mock.stub(FailingMockEncodingRequest.self, with: EmptyResponse())
        let task = Task {
            await gate.wait()
            return try await mock.send(FailingMockEncodingRequest())
        }

        task.cancel()
        await gate.signal()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await mock.recordedRequests.isEmpty)
    }

    @Test("Cancellation during a mock delay remains CancellationError")
    func cancellation() async throws {
        let started = AsyncSignal()
        let mock = MockAPIClient(delay: 60) { _ in
            await started.signal()
            try await Task.sleep(nanoseconds: UInt64.max)
        }
        await mock.stub(
            GetUserRequest.self,
            with: TestUser(id: 1, displayName: "Never returned")
        )
        let task = Task {
            try await mock.send(GetUserRequest(id: 1))
        }

        await started.wait()
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("Concurrent sends are recorded exactly once with unique sequence IDs")
    func concurrentRecording() async throws {
        let mock = MockAPIClient()
        await mock.stub(
            GetUserRequest.self,
            with: TestUser(id: 1, displayName: "Concurrent")
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in 0..<100 {
                group.addTask {
                    _ = try await mock.send(GetUserRequest(id: id))
                }
            }
            try await group.waitForAll()
        }

        let records = await mock.recordedRequests
        #expect(records.count == 100)
        #expect(records.map(\.sequenceID).sorted() == Array(0..<100))
        #expect(Set(records.map(\.path)).count == 100)
    }

    @Test("Compatibility aliases remain actor-safe and observable")
    func compatibilityAliases() async throws {
        let mock = MockAPIClient()
        let ordinary = TestUser(id: 1, displayName: "Ordinary")
        let page = PaginatedResponse(
            items: [TestUser(id: 2, displayName: "Page")],
            currentPage: 2,
            totalPages: 3
        )
        await mock.mock(GetUserRequest.self, with: ordinary)
        await mock.mock(MockPageRequest.self, with: page)

        #expect(try await mock.send(GetUserRequest(id: 1)) == ordinary)
        #expect(try await mock.sendPage(
            MockPageRequest(page: 2, pageSize: 20, filter: "active")
        ) == page)
        #expect(await mock.calledRequests == ["users/1", "users?page=2"])

        await mock.resetMocks()
        #expect(await mock.recordedRequests.isEmpty)
    }

    @Test("Exact compatibility aliases and exact page errors still work")
    func exactCompatibilityAliases() async throws {
        let mock = MockAPIClient()
        let request = GetUserRequest(id: 1)
        let pageRequest = MockPageRequest(page: 2, pageSize: 20, filter: "active")
        try await mock.mock(
            request,
            with: TestUser(id: 1, displayName: "Exact")
        )
        try await mock.mockError(
            GetUserRequest(id: 2),
            with: MockFixtureError.exact
        )
        try await mock.stubPageError(
            pageRequest,
            error: MockFixtureError.typeDefault
        )

        #expect(try await mock.send(request).displayName == "Exact")
        await #expect(throws: MockFixtureError.exact) {
            try await mock.send(GetUserRequest(id: 2))
        }
        await #expect(throws: MockFixtureError.typeDefault) {
            try await mock.sendPage(pageRequest)
        }
    }

    @Test("Request construction failures remain typed in registration and sends")
    func requestConstructionFailures() async throws {
        let mock = MockAPIClient()

        do {
            try await mock.stub(
                InvalidMockURLRequest(),
                with: EmptyResponse()
            )
            Issue.record("Expected exact registration to reject the URL")
        } catch let error as NetworkError {
            guard case .invalidURL = error else {
                Issue.record("Expected invalidURL, got \(error)")
                return
            }
        }

        await mock.stub(FailingMockEncodingRequest.self, with: EmptyResponse())
        do {
            _ = try await mock.send(FailingMockEncodingRequest())
            Issue.record("Expected mock body encoding to fail")
        } catch let error as NetworkError {
            guard case .encodingFailed(let underlying) = error else {
                Issue.record("Expected encodingFailed, got \(error)")
                return
            }
            #expect(underlying is MockFixtureError)
        }

        do {
            try await mock.stub(
                CancellingMockEncodingRequest(),
                with: EmptyResponse()
            )
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("Missing-stub diagnostics are localized")
    func localizedDiagnostics() async throws {
        let mock = MockAPIClient()

        do {
            _ = try await mock.send(GetUserRequest(id: 404))
            Issue.record("Expected a missing stub")
        } catch let error as MockAPIClientError {
            #expect(error.localizedDescription.contains("No request stub"))
            #expect(error.localizedDescription.contains("users/404"))
        }
    }
}

private struct MockUserService: Sendable {
    let client: any APIClientProtocol

    func user(id: Int) async throws -> TestUser {
        try await client.send(GetUserRequest(id: id))
    }
}

private struct MockPageRequest: PaginatedRequest {
    typealias ReturnType = TestUser

    let page: Int
    let pageSize: Int
    let filter: String
    let path = "users"
    var queryItems: [URLQueryItem]? {
        [URLQueryItem(name: "filter", value: filter)]
    }
}

private struct RecordingRequest: Request {
    typealias ReturnType = EmptyResponse

    let path = "record"
    let method = HTTPMethod.post
    let queryItems: [URLQueryItem]? = [URLQueryItem(name: "q", value: "value")]
    let headers: [String: String]? = ["X-Test": "header"]
    let body: Data? = Data("body".utf8)
}

private struct EncodedBodyRequest: Request {
    typealias ReturnType = TestUser

    private struct Payload: Encodable {
        let displayName: String
    }

    let displayName: String
    let path = "encoded"
    let method = HTTPMethod.post

    func makeBody(using encoder: JSONEncoder) throws -> Data? {
        try encoder.encode(Payload(displayName: displayName))
    }
}

private struct CustomURLRequest: Request {
    typealias ReturnType = TestUser

    let variant: String
    let path = "shared"

    func makeURL(baseURL: URL) -> URL? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "variant", value: variant)]
        return components.url
    }
}

private struct OrderedQueryRequest: Request {
    typealias ReturnType = TestUser

    let values: [String]
    let path = "ordered"
    var queryItems: [URLQueryItem]? {
        values.map { URLQueryItem(name: "value", value: $0) }
    }
}

private struct FailingMockEncodingRequest: Request {
    typealias ReturnType = EmptyResponse

    let path = "failing-encoding"

    func makeBody(using encoder: JSONEncoder) throws -> Data? {
        throw MockFixtureError.exact
    }
}

private struct InvalidMockURLRequest: Request {
    typealias ReturnType = EmptyResponse

    let path = "invalid"

    func makeURL(baseURL: URL) -> URL? {
        nil
    }
}

private struct CancellingMockEncodingRequest: Request {
    typealias ReturnType = EmptyResponse

    let path = "cancelling-encoding"

    func makeBody(using encoder: JSONEncoder) throws -> Data? {
        throw CancellationError()
    }
}

private enum MockFixtureError: Error, Equatable {
    case typeDefault
    case exact
}
