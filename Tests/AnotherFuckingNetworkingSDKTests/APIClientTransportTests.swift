import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("APIClient transport")
struct APIClientTransportTests {
    @Test("A missing base URL fails before transport")
    func invalidURL() async throws {
        let client = APIClient(baseURL: nil)

        do {
            _ = try await client.send(GetUserRequest(id: 1))
            Issue.record("Expected invalidURL")
        } catch let error as NetworkError {
            guard case .invalidURL = error else {
                Issue.record("Expected invalidURL, got \(error)")
                return
            }
        }
    }

    @Test("Successful JSON uses the configured decoder")
    func configuredDecoding() async throws {
        let body = Data(#"{"id":42,"display_name":"Arthur"}"#.utf8)
        let stub = StubSession { request in
            .respond(try .http(for: request, data: body))
        }
        let client = stub.client(decoderFactory: {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return decoder
        })

        let user = try await client.send(GetUserRequest(id: 42))

        #expect(user == TestUser(id: 42, displayName: "Arthur"))
    }

    @Test("Invalid JSON remains a decoding error")
    func decodingFailure() async throws {
        let stub = StubSession { request in
            .respond(try .http(for: request, data: Data("not-json".utf8)))
        }

        do {
            _ = try await stub.client().send(GetUserRequest(id: 1))
            Issue.record("Expected a decoding error")
        } catch let error as NetworkError {
            guard case .decodingFailed(let underlying) = error else {
                Issue.record("Expected decodingFailed, got \(error)")
                return
            }
            #expect(underlying is DecodingError)
        }
    }

    @Test("A request may customize successful response decoding")
    func customDecoding() async throws {
        let stub = StubSession { request in
            .respond(try .http(for: request, data: Data("42".utf8)))
        }

        let result = try await stub.client().send(CustomDecodingRequest())

        #expect(result == TestUser(id: 42, displayName: "Custom"))
    }

    @Test("Response sends preserve status, headers, URL, and raw bytes")
    func responseMetadata() async throws {
        let body = Data(#"{"id":42,"displayName":"Arthur"}"#.utf8)
        let stub = StubSession { request in
            .respond(try .http(
                for: request,
                statusCode: 201,
                headers: ["X-RateLimit-Remaining": "9"],
                data: body
            ))
        }
        let client: any APIClientResponseProtocol = stub.client()

        let response = try await client.sendResponse(GetUserRequest(id: 42))

        #expect(response.value == TestUser(id: 42, displayName: "Arthur"))
        #expect(response.data == body)
        #expect(response.statusCode == 201)
        #expect(response.url == stub.baseURL.appendingPathComponent("users/42"))
        #expect(response.headers["x-ratelimit-remaining"] == "9")
        #expect(response.value(forHTTPHeaderField: "X-RATELIMIT-REMAINING") == "9")
    }

    @Test("Raw requests return bytes without JSON decoding")
    func rawData() async throws {
        let body = Data([0x00, 0x01, 0xFE, 0xFF])
        let stub = StubSession { request in
            .respond(try .http(for: request, data: body))
        }

        let response = try await stub.client().sendResponse(RawFixtureRequest())

        #expect(response.value == body)
        #expect(response.data == body)
    }

    @Test("HTTP byte streams expose metadata before body bytes")
    func byteStream() async throws {
        let body = Data([0x00, 0x01, 0xFE, 0xFF])
        let stub = StubSession { request in
            .respond(try .http(
                for: request,
                statusCode: 200,
                headers: ["Content-Type": "application/octet-stream"],
                data: body
            ))
        }

        let stream = try await stub.client().stream(GetUserRequest(id: 42))
        #expect(stream.statusCode == 200)
        #expect(stream.value(forHTTPHeaderField: "content-type") == "application/octet-stream")

        var received = Data()
        for try await byte in stream {
            received.append(byte)
        }
        #expect(received == body)
    }

    @Test("Rejected byte streams preserve bounded failure data")
    func byteStreamFailure() async throws {
        let body = Data("stream failure".utf8)
        let stub = StubSession { request in
            .respond(try .http(
                for: request,
                statusCode: 429,
                headers: ["Retry-After": "0"],
                data: body
            ))
        }

        do {
            _ = try await stub.client().stream(GetUserRequest(id: 42))
            Issue.record("Expected requestFailed")
        } catch let error as NetworkError {
            guard case .requestFailed(let failure) = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
            #expect(failure.statusCode == 429)
            #expect(failure.data == body)
        }
    }

    @Test("Streaming activity remains active until EOF")
    func byteStreamActivityLifecycle() async throws {
        let stub = StubSession { request in
            .respond(try .http(for: request, data: Data("streamed".utf8)))
        }
        let monitor = NetworkActivityMonitor()
        let stream = try await stub.client(activityMonitor: monitor).stream(
            GetUserRequest(id: 42)
        )

        #expect(monitor.currentSnapshot.activeCount(for: .stream) == 1)
        for try await _ in stream {}
        #expect(monitor.currentSnapshot.activeCount(for: .stream) == 0)
        #expect(monitor.currentSnapshot.succeededCount == 1)
    }

    @Test("Raw requests accept empty successful bodies", arguments: [200, 204, 205])
    func emptyRawData(statusCode: Int) async throws {
        let stub = StubSession { request in
            .respond(try .http(for: request, statusCode: statusCode))
        }

        let data = try await stub.client().send(RawFixtureRequest())

        #expect(data.isEmpty)
    }

    @Test("Custom decoders may return non-Decodable values")
    func nonDecodableReturnType() async throws {
        let stub = StubSession { request in
            .respond(try .http(for: request, data: Data("answer".utf8)))
        }

        let value = try await stub.client().send(PlainValueRequest())

        #expect(value == PlainValue(text: "answer"))
    }

    @Test("Request customization sees and can refine the prepared URLRequest")
    func requestCustomization() async throws {
        let captured = LockedBox<URLRequest?>(nil)
        let body = Data(#"{"id":1,"displayName":"Ford"}"#.utf8)
        let stub = StubSession { request in
            captured.withLock { $0 = request }
            return .respond(try .http(for: request, data: body))
        }
        let client = stub.client(globalHeaders: ["X-Global": "present"])

        _ = try await client.send(CustomizedRequest())

        let request = try #require(captured.withLock { $0 })
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 7)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "X-Global") == "present")
        #expect(request.value(forHTTPHeaderField: "X-Request") == "prepared")
        #expect(request.value(forHTTPHeaderField: "X-Signature") == "POST:payload")
        #expect(requestBodyData(request) == Data("payload".utf8))
    }

    @Test("Request customization errors remain typed")
    func requestCustomizationFailure() async throws {
        let client = APIClient(baseURL: URL(string: "https://example.com"))

        do {
            _ = try await client.send(FailingCustomizationRequest())
            Issue.record("Expected customization to fail")
        } catch let error as NetworkError {
            guard case .requestConfigurationFailed(let underlying) = error else {
                Issue.record("Expected requestConfigurationFailed, got \(error)")
                return
            }
            #expect(underlying is CustomizationFixtureError)
        }
    }

    @Test("Cancellation thrown during request customization is preserved")
    func requestCustomizationCancellation() async throws {
        let client = APIClient(baseURL: URL(string: "https://example.com"))

        do {
            _ = try await client.send(CancellingCustomizationRequest())
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("Request-specific headers override defaults case-insensitively")
    func caseInsensitiveHeaderOverride() async throws {
        let capturedAuthorization = LockedBox<String?>(nil)
        let body = Data(#"{"id":1,"displayName":"Ford"}"#.utf8)
        let stub = StubSession { request in
            capturedAuthorization.withLock {
                $0 = request.value(forHTTPHeaderField: "Authorization")
            }
            return .respond(try .http(for: request, data: body))
        }
        let client = stub.client(globalHeaders: [
            "authorization": "Bearer global",
            "Authorization": "Bearer duplicate",
            "Accept": "application/json"
        ])

        _ = try await client.send(HeaderRequest())

        #expect(capturedAuthorization.withLock { $0 } == "Bearer request")
    }

    @Test("Case-variant duplicates are collapsed deterministically")
    func duplicateHeaderNormalization() async throws {
        let captured = LockedBox<[String?]>([])
        let body = Data(#"{"id":1,"displayName":"Ford"}"#.utf8)
        let stub = StubSession { request in
            captured.withLock {
                $0.append(request.value(forHTTPHeaderField: "X-Duplicate"))
            }
            return .respond(try .http(for: request, data: body))
        }
        let client = stub.client(globalHeaders: [
            "X-Duplicate": "uppercase default",
            "x-duplicate": "lowercase default"
        ])

        _ = try await client.send(GetUserRequest(id: 1))
        _ = try await client.send(DuplicateHeaderRequest())

        #expect(captured.withLock { $0 } == [
            "lowercase default",
            "lowercase override"
        ])
    }

    @Test("Request bodies use a fresh configured encoder")
    func configuredEncoding() async throws {
        let capturedBody = LockedBox<Data?>(nil)
        let responseBody = Data(#"{"id":7,"displayName":"Zaphod"}"#.utf8)
        let stub = StubSession { request in
            capturedBody.withLock { $0 = requestBodyData(request) }
            return .respond(try .http(for: request, data: responseBody))
        }
        let client = stub.client(encoderFactory: {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            return encoder
        })

        _ = try await client.send(CreateUserRequest(displayName: "Trillian"))

        let encodedBody = try #require(capturedBody.withLock { $0 })
        let jsonObject = try JSONSerialization.jsonObject(with: encodedBody)
        let object = try #require(jsonObject as? [String: String])
        #expect(object == ["display_name": "Trillian"])
    }

    @Test("Body encoding errors remain typed")
    func encodingFailure() async throws {
        let stub = StubSession { request in
            .respond(try .http(for: request))
        }

        do {
            _ = try await stub.client().send(FailingEncodingRequest())
            Issue.record("Expected encoding to fail")
        } catch let error as NetworkError {
            guard case .encodingFailed(let underlying) = error else {
                Issue.record("Expected encodingFailed, got \(error)")
                return
            }
            #expect(underlying is EncodingFixtureError)
        }
    }

    @Test("Cancellation thrown during body encoding is preserved")
    func encodingCancellation() async throws {
        let client = APIClient(baseURL: URL(string: "https://example.com"))

        do {
            _ = try await client.send(CancellingEncodingRequest())
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("A pre-cancelled task never attempts body encoding")
    func cancellationBeforeEncoding() async throws {
        let gate = AsyncSignal()
        let client = APIClient(baseURL: URL(string: "https://example.com"))
        let task = Task {
            await gate.wait()
            return try await client.send(FailingEncodingRequest())
        }

        task.cancel()
        await gate.signal()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("Cancellation thrown during custom decoding is preserved")
    func decodingCancellation() async throws {
        let stub = StubSession { request in
            .respond(try .http(for: request, data: Data("{}".utf8)))
        }

        do {
            _ = try await stub.client().send(CancellingDecodeRequest())
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test("EmptyResponse accepts 204 responses")
    func emptyResponse() async throws {
        let stub = StubSession { request in
            .respond(try .http(for: request, statusCode: 204))
        }

        let response = try await stub.client().send(EmptyRequest(path: "users/1"))

        #expect(response == EmptyResponse())
    }

    @Test("EmptyResponse accepts 205 and zero-byte 200 responses", arguments: [205, 200])
    func otherEmptyResponses(statusCode: Int) async throws {
        let stub = StubSession { request in
            .respond(try .http(for: request, statusCode: statusCode))
        }

        #expect(try await stub.client().send(EmptyRequest(path: "empty")) == EmptyResponse())
    }

    @Test("EmptyResponse can decode a nonempty successful JSON body")
    func nonemptyEmptyResponse() async throws {
        let stub = StubSession { request in
            .respond(try .http(for: request, data: Data("{}".utf8)))
        }

        #expect(try await stub.client().send(EmptyRequest(path: "empty")) == EmptyResponse())
    }

    @Test("An empty body for a model throws emptyResponse")
    func unexpectedEmptyResponse() async throws {
        let stub = StubSession { request in
            .respond(try .http(for: request))
        }

        do {
            _ = try await stub.client().send(GetUserRequest(id: 1))
            Issue.record("Expected an empty response error")
        } catch let error as NetworkError {
            guard case .emptyResponse(let statusCode) = error else {
                Issue.record("Expected emptyResponse, got \(error)")
                return
            }
            #expect(statusCode == 200)
        }
    }

    @Test("Non-2xx responses preserve metadata and body")
    func statusFailure() async throws {
        let body = Data(#"{"message":"unauthorized"}"#.utf8)
        let finalURL = URL(string: "https://edge.example.com/v2/users/1")!
        let stub = StubSession { request in
            .respond(try .http(
                for: request,
                responseURL: finalURL,
                statusCode: 401,
                headers: [
                    "Retry-After": "30",
                    "X-Request-ID": "request-1"
                ],
                data: body
            ))
        }

        do {
            _ = try await stub.client().send(GetUserRequest(id: 1))
            Issue.record("Expected a status error")
        } catch let error as NetworkError {
            guard case .requestFailed(let failure) = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
            #expect(failure.statusCode == 401)
            #expect(failure.data == body)
            #expect(failure.url == finalURL)
            #expect(failure.value(forHTTPHeaderField: "retry-after") == "30")
            #expect(failure.value(forHTTPHeaderField: "X-REQUEST-ID") == "request-1")
        }
    }

    @Test("The default status policy accepts the complete 2xx boundary", arguments: [200, 299])
    func defaultStatusSuccessBoundaries(statusCode: Int) async throws {
        let body = Data(#"{"id":1,"displayName":"Accepted"}"#.utf8)
        let stub = StubSession { request in
            .respond(try .http(
                for: request,
                statusCode: statusCode,
                data: body
            ))
        }

        let response = try await stub.client().sendResponse(
            GetUserRequest(id: 1)
        )

        #expect(response.statusCode == statusCode)
        #expect(response.value == TestUser(id: 1, displayName: "Accepted"))
    }

    @Test("Requests can widen or narrow accepted response statuses")
    func requestSpecificStatusPolicy() async throws {
        let body = Data(#"{"id":1,"displayName":"Policy"}"#.utf8)
        let acceptedStub = StubSession { request in
            .respond(try .http(
                for: request,
                statusCode: 409,
                data: body
            ))
        }
        let accepted = try await acceptedStub.client().sendResponse(
            StatusPolicyRequest(acceptedStatusCodes: .codes([409]))
        )
        #expect(accepted.statusCode == 409)
        #expect(accepted.value == TestUser(id: 1, displayName: "Policy"))

        let rejectedStub = StubSession { request in
            .respond(try .http(
                for: request,
                statusCode: 299,
                data: body
            ))
        }
        do {
            _ = try await rejectedStub.client().send(
                StatusPolicyRequest(acceptedStatusCodes: .codes([201]))
            )
            Issue.record("Expected the request-specific status rejection")
        } catch let error as NetworkError {
            guard case .requestFailed(let failure) = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
            #expect(failure.statusCode == 299)
            #expect(failure.data == body)
        }
    }

    @Test("A response status policy is captured once before transport suspension")
    func statusPolicySnapshot() async throws {
        let state = LockedBox((
            reads: 0,
            policy: HTTPStatusPolicy.codes([202])
        ))
        let body = Data(#"{"id":1,"displayName":"Snapshot"}"#.utf8)
        let stub = StubSession { request in
            state.withLock { $0.policy = .none }
            return .respond(try .http(
                for: request,
                statusCode: 202,
                data: body
            ))
        }

        let response = try await stub.client().sendResponse(
            SnapshotStatusPolicyRequest(state: state)
        )

        #expect(response.statusCode == 202)
        #expect(state.withLock { $0.reads } == 1)
    }

    @Test("Status acceptance remains independent from empty-body acceptance")
    func statusPolicyDoesNotAcceptEmptyBody() async throws {
        let stub = StubSession { request in
            .respond(try .http(for: request, statusCode: 304))
        }

        do {
            _ = try await stub.client().send(StatusPolicyRequest(
                acceptedStatusCodes: .codes([304])
            ))
            Issue.record("Expected the accepted status to fail body decoding")
        } catch let error as NetworkError {
            guard case .emptyResponse(let statusCode) = error else {
                Issue.record("Expected emptyResponse, got \(error)")
                return
            }
            #expect(statusCode == 304)
        }
    }

    @Test("The complete non-2xx boundary is rejected", arguments: [199, 300, 500])
    func statusBoundaries(statusCode: Int) async throws {
        let stub = StubSession { request in
            .respond(try .http(for: request, statusCode: statusCode))
        }

        do {
            _ = try await stub.client().send(GetUserRequest(id: 1))
            Issue.record("Expected HTTP \(statusCode) to fail")
        } catch let error as NetworkError {
            guard case .requestFailed(let failure) = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
            #expect(failure.statusCode == statusCode)
        }
    }

    @Test("Non-HTTP URL responses remain distinct")
    func invalidResponse() async throws {
        let stub = StubSession { request in
            let response = URLResponse(
                url: try #require(request.url),
                mimeType: nil,
                expectedContentLength: 0,
                textEncodingName: nil
            )
            return .respond(.init(response: response, data: Data()))
        }

        do {
            _ = try await stub.client().send(GetUserRequest(id: 1))
            Issue.record("Expected invalidResponse")
        } catch let error as NetworkError {
            guard case .invalidResponse = error else {
                Issue.record("Expected invalidResponse, got \(error)")
                return
            }
        }
    }

    @Test("URL errors remain typed transport errors")
    func transportFailure() async throws {
        let stub = StubSession { _ in .fail(URLError(.timedOut)) }

        do {
            _ = try await stub.client().send(GetUserRequest(id: 1))
            Issue.record("Expected a transport error")
        } catch let error as NetworkError {
            guard case .transport(let urlError) = error else {
                Issue.record("Expected transport, got \(error)")
                return
            }
            #expect(urlError.code == .timedOut)
        }
    }

    @Test("An unrelated URL cancellation remains a typed transport error")
    func transportCancellationWithoutTaskCancellation() async throws {
        let stub = StubSession { _ in .fail(URLError(.cancelled)) }

        do {
            _ = try await stub.client().send(GetUserRequest(id: 1))
            Issue.record("Expected a transport error")
        } catch let error as NetworkError {
            guard case .transport(let urlError) = error else {
                Issue.record("Expected transport, got \(error)")
                return
            }
            #expect(urlError.code == .cancelled)
        }
    }

    @Test("Unexpected transport failures remain inspectable")
    func unknownTransportFailure() async throws {
        let stub = StubSession { _ in .fail(UnexpectedTransportError.fixture) }

        do {
            _ = try await stub.client().send(GetUserRequest(id: 1))
            Issue.record("Expected an unknown transport error")
        } catch let error as NetworkError {
            guard case .unknown(let underlying) = error else {
                Issue.record("Expected unknown, got \(error)")
                return
            }
            let bridgedError = underlying as NSError
            #expect(bridgedError.domain.contains("UnexpectedTransportError"))
        }
    }

    @Test("Task cancellation remains CancellationError")
    func cancellation() async throws {
        let started = AsyncSignal()
        let stopped = AsyncSignal()
        let stub = StubSession { _ in
            .pending(
                onStart: { Task { await started.signal() } },
                onStop: { Task { await stopped.signal() } }
            )
        }
        let client = stub.client()
        let task = Task {
            try await client.send(GetUserRequest(id: 1))
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

    @Test("Atomic configuration updates never produce mixed snapshots")
    func atomicConfigurationSnapshots() async throws {
        let invalidSnapshot = LockedBox(false)
        let stub = StubSession { request in
            let version = request.value(forHTTPHeaderField: "X-Version")
            let path = request.url?.path
            let isValid = (version == "1" && path == "/v1/check")
                || (version == "2" && path == "/v2/check")
            if !isValid {
                invalidSnapshot.withLock { $0 = true }
            }
            return .respond(try .http(for: request, statusCode: 204))
        }
        let versionOneURL = stub.baseURL.appendingPathComponent("v1")
        let versionTwoURL = stub.baseURL.appendingPathComponent("v2")
        let client = stub.client(
            baseURL: versionOneURL,
            globalHeaders: ["X-Version": "1"]
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<200 {
                group.addTask {
                    client.updateConfiguration { configuration in
                        if index.isMultiple(of: 2) {
                            configuration.baseURL = versionOneURL
                            configuration.globalHeaders = ["X-Version": "1"]
                        } else {
                            configuration.baseURL = versionTwoURL
                            configuration.globalHeaders = ["X-Version": "2"]
                        }
                    }
                }
                group.addTask {
                    _ = try await client.send(EmptyRequest(path: "check"))
                }
            }
            try await group.waitForAll()
        }

        #expect(!invalidSnapshot.withLock { $0 })
    }
}

private struct HeaderRequest: Request {
    typealias ReturnType = TestUser
    let path = "users/1"
    let headers: [String: String]? = ["Authorization": "Bearer request"]
}

private struct StatusPolicyRequest: Request {
    typealias ReturnType = TestUser

    let acceptedStatusCodes: HTTPStatusPolicy
    let path = "status-policy"
}

private struct SnapshotStatusPolicyRequest: Request {
    typealias ReturnType = TestUser

    let state: LockedBox<(reads: Int, policy: HTTPStatusPolicy)>
    let path = "status-policy-snapshot"

    var acceptedStatusCodes: HTTPStatusPolicy {
        state.withLock {
            $0.reads += 1
            return $0.policy
        }
    }
}

private struct DuplicateHeaderRequest: Request {
    typealias ReturnType = TestUser
    let path = "users/1"
    let headers: [String: String]? = [
        "X-Duplicate": "uppercase override",
        "x-duplicate": "lowercase override"
    ]
}

private struct CreateUserRequest: Request {
    typealias ReturnType = TestUser

    struct Payload: Encodable, Sendable {
        let displayName: String
    }

    let displayName: String
    let path = "users"
    let method = HTTPMethod.post

    func makeBody(using encoder: JSONEncoder) throws -> Data? {
        try encoder.encode(Payload(displayName: displayName))
    }
}

private enum EncodingFixtureError: Error {
    case expected
}

private enum UnexpectedTransportError: Error {
    case fixture
}

private struct FailingEncodingRequest: Request {
    typealias ReturnType = EmptyResponse
    let path = "failure"

    func makeBody(using encoder: JSONEncoder) throws -> Data? {
        throw EncodingFixtureError.expected
    }
}

private struct CancellingEncodingRequest: Request {
    typealias ReturnType = EmptyResponse
    let path = "cancel-encoding"

    func makeBody(using encoder: JSONEncoder) throws -> Data? {
        throw CancellationError()
    }
}

private struct CancellingDecodeRequest: Request {
    typealias ReturnType = EmptyResponse
    let path = "cancel-decoding"

    func decode(
        _ data: Data,
        response: HTTPURLResponse,
        using decoder: JSONDecoder
    ) throws -> EmptyResponse {
        throw CancellationError()
    }
}

private struct CustomDecodingRequest: Request {
    typealias ReturnType = TestUser
    let path = "custom"

    func decode(
        _ data: Data,
        response: HTTPURLResponse,
        using decoder: JSONDecoder
    ) throws -> TestUser {
        let id = try #require(Int(String(decoding: data, as: UTF8.self)))
        return TestUser(id: id, displayName: "Custom")
    }
}

private struct RawFixtureRequest: RawDataRequest {
    let path = "raw"
}

private struct PlainValue: Equatable, Sendable {
    let text: String
}

private struct PlainValueRequest: Request {
    typealias ReturnType = PlainValue
    let path = "plain"

    func decode(
        _ data: Data,
        response: HTTPURLResponse,
        using decoder: JSONDecoder
    ) throws -> PlainValue {
        PlainValue(text: String(decoding: data, as: UTF8.self))
    }
}

private struct CustomizedRequest: Request {
    typealias ReturnType = TestUser
    let path = "customized"
    let method = HTTPMethod.post
    let body: Data? = Data("payload".utf8)
    let headers: [String: String]? = ["X-Request": "prepared"]

    func customize(_ urlRequest: inout URLRequest) throws {
        let method = urlRequest.httpMethod ?? "missing"
        let body = String(decoding: urlRequest.httpBody ?? Data(), as: UTF8.self)
        urlRequest.timeoutInterval = 7
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.setValue("\(method):\(body)", forHTTPHeaderField: "X-Signature")
    }
}

private enum CustomizationFixtureError: Error {
    case expected
}

private struct FailingCustomizationRequest: Request {
    typealias ReturnType = EmptyResponse
    let path = "customization-failure"

    func customize(_ urlRequest: inout URLRequest) throws {
        throw CustomizationFixtureError.expected
    }
}

private struct CancellingCustomizationRequest: Request {
    typealias ReturnType = EmptyResponse
    let path = "customization-cancellation"

    func customize(_ urlRequest: inout URLRequest) throws {
        throw CancellationError()
    }
}
