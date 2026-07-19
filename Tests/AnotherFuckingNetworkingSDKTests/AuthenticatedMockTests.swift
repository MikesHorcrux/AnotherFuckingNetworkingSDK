import Foundation
import Testing
import AnotherFuckingNetworkingSDKTesting
@testable import AnotherFuckingNetworkingSDK

@Suite("Authenticated mock adapters")
struct AuthenticatedMockTests {
    @Test("Mock streams are finite, typed, and recorded separately")
    func streamStub() async throws {
        let mock = MockAPIClient()
        let payload = Data("streamed by mock".utf8)
        await mock.stubStream(GetUserRequest.self, data: payload)

        let client: any APIClientStreamingProtocol = mock
        let stream = try await client.stream(GetUserRequest(id: 42))
        var received = Data()
        for try await byte in stream {
            received.append(byte)
        }

        #expect(received == payload)
        let records = await mock.recordedRequests
        #expect(records.count == 1)
        #expect(records.first?.operation == .stream)
        #expect(records.first?.path == "users/42")
    }

    @Test("Missing mock streams preserve the recorded invocation")
    func missingStreamStub() async throws {
        let mock = MockAPIClient()

        do {
            _ = try await mock.stream(GetUserRequest(id: 7))
            Issue.record("Expected a missing stream stub error")
        } catch let error as MockAPIClientError {
            guard case .missingStub(let request) = error else {
                Issue.record("Expected missingStub, got \(error)")
                return
            }
            #expect(request.operation == .stream)
            #expect(request.path == "users/7")
        }
    }

    @Test("Authenticated façades inject bearer credentials into mock requests")
    func authenticatedRequest() async throws {
        let mock = MockAPIClient()
        await mock.stubResponse(
            GetUserRequest.self,
            with: HTTPResponse(
                value: TestUser(id: 42, displayName: "Arthur"),
                metadata: HTTPResponseMetadata(statusCode: 200)
            )
        )
        let provider = SingleFlightTokenProvider(
            loader: { AccessToken(value: "mock-token") },
            refreshLoader: { AccessToken(value: "refreshed-token") }
        )
        let client = AuthenticatedAPIClient(
            client: mock,
            authenticator: provider
        )

        #expect(try await client.send(GetUserRequest(id: 42)) == TestUser(
            id: 42,
            displayName: "Arthur"
        ))
        let records = await mock.recordedRequests
        #expect(records.first?.headers["authorization"] == "Bearer mock-token")
    }

    @Test("Authenticated façades forward mock streams and credentials")
    func authenticatedStream() async throws {
        let mock = MockAPIClient()
        let payload = Data("authenticated stream".utf8)
        await mock.stubStream(GetUserRequest.self, data: payload)
        let provider = SingleFlightTokenProvider(
            loader: { AccessToken(value: "stream-token") },
            refreshLoader: { AccessToken(value: "refreshed-token") }
        )
        let client = AuthenticatedAPIClient(
            client: mock,
            authenticator: provider
        )

        let stream = try await client.stream(GetUserRequest(id: 42))
        var received = Data()
        for try await byte in stream {
            received.append(byte)
        }

        #expect(received == payload)
        let records = await mock.recordedRequests
        #expect(records.first?.operation == .stream)
        #expect(records.first?.headers["authorization"] == "Bearer stream-token")
    }

    @Test("Authenticated façades preserve mock transfer progress")
    func authenticatedUploadProgress() async throws {
        let mock = MockAPIClient()
        let body = Data("upload body".utf8)
        await mock.stubUpload(
            MockUploadRequest.self,
            with: HTTPResponse(
                value: Data("ok".utf8),
                metadata: HTTPResponseMetadata(statusCode: 200)
            )
        )
        let provider = SingleFlightTokenProvider(
            loader: { AccessToken(value: "upload-token") },
            refreshLoader: { AccessToken(value: "refreshed-token") }
        )
        let authenticated = AuthenticatedAPIClient(
            client: mock,
            authenticator: provider
        )
        let client: any APIClientTransferProgressProtocol = authenticated
        let events = LockedBox<[TransferProgress]>([])

        let response = try await client.upload(
            MockUploadRequest(),
            from: .data(body),
            progress: { event in
                events.withLock { $0.append(event) }
            }
        )

        #expect(response.value == Data("ok".utf8))
        #expect(events.withLock { $0 }.map(\.phase) == [.started, .completed])
        let records = await mock.recordedTransfers
        #expect(records.first?.headers["authorization"] == "Bearer upload-token")
        #expect(records.first?.requestBody == body)
    }
}

private struct MockUploadRequest: RawDataRequest {
    let path = "upload"
    let method = HTTPMethod.post
}
