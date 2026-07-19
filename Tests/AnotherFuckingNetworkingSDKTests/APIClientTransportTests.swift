import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("APIClient transport")
struct APIClientTransportTests {
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
            "Accept": "application/json"
        ])

        _ = try await client.send(HeaderRequest())

        #expect(capturedAuthorization.withLock { $0 } == "Bearer request")
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

    @Test("EmptyResponse accepts 204 responses")
    func emptyResponse() async throws {
        let stub = StubSession { request in
            .respond(try .http(for: request, statusCode: 204))
        }

        let response = try await stub.client().send(EmptyRequest(path: "users/1"))

        #expect(response == EmptyResponse())
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

    @Test("Non-2xx responses preserve status and body")
    func statusFailure() async throws {
        let body = Data(#"{"message":"unauthorized"}"#.utf8)
        let stub = StubSession { request in
            .respond(try .http(for: request, statusCode: 401, data: body))
        }

        do {
            _ = try await stub.client().send(GetUserRequest(id: 1))
            Issue.record("Expected a status error")
        } catch let error as NetworkError {
            guard case .requestFailed(let statusCode, let errorBody) = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
            #expect(statusCode == 401)
            #expect(errorBody == body)
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
}

private struct HeaderRequest: Request {
    typealias ReturnType = TestUser
    let path = "users/1"
    let headers: [String: String]? = ["Authorization": "Bearer request"]
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

private struct FailingEncodingRequest: Request {
    typealias ReturnType = EmptyResponse
    let path = "failure"

    func makeBody(using encoder: JSONEncoder) throws -> Data? {
        throw EncodingFixtureError.expected
    }
}
