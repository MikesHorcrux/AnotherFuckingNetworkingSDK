import Foundation
import Testing
import AnotherFuckingNetworkingSDK
import AnotherFuckingNetworkingSDKTesting

/// Compile-checked counterparts of the canonical README examples.
@Suite("Documentation examples")
struct DocumentationExamplesTests {
    @Test("Service injection and ordinary stubs compile and run")
    func serviceInjection() async throws {
        let mock = MockAPIClient()
        await mock.stub(
            DocumentationGetUserRequest.self,
            with: DocumentationUser(id: 0, displayName: "Default")
        )
        let expected = DocumentationUser(id: 42, displayName: "Arthur")
        try await mock.stub(
            DocumentationGetUserRequest(userID: 42),
            with: expected
        )
        let service = DocumentationUserService(client: mock)

        let user = try await service.user(id: 42)
        let calls = await mock.recordedRequests

        #expect(user == expected)
        #expect(calls.map(\.path) == ["users/42"])
    }

    @Test("Paginated mock registration is compile-time safe")
    func paginatedMocking() async throws {
        let mock = MockAPIClient()
        let expected = PaginatedResponse(
            items: [DocumentationUser(id: 1, displayName: "Trillian")],
            currentPage: 1,
            totalPages: 1
        )
        await mock.stubPage(DocumentationListUsersRequest.self, with: expected)

        let response = try await mock.sendPage(
            DocumentationListUsersRequest(page: 1, pageSize: 50, role: "admin")
        )

        #expect(response == expected)
    }

    @Test("Configured encoding and logging examples compile")
    func configurationExamples() throws {
        let client = APIClient(
            baseURL: URL(string: "https://api.example.com")!,
            encoderFactory: {
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                return encoder
            },
            decoderFactory: {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return decoder
            },
            logger: NetworkingLogger(
                configuration: .init(
                    bodyPolicy: .redactedJSON(maximumBytes: 16_384)
                )
            )
        )
        let request = DocumentationCreateUserRequest(
            payload: .init(displayName: "Ford")
        )

        let body = try request.makeBody(using: client.configuration.encoderFactory())
        let object = try JSONSerialization.jsonObject(with: try #require(body))
            as? [String: String]

        #expect(object == ["display_name": "Ford"])
    }

    @Test("Shared configuration and custom sinks compile")
    func sharedConfigurationAndSink() {
        let client = APIClient.shared
        let previousConfiguration = client.configuration
        defer { client.configuration = previousConfiguration }

        client.updateConfiguration { configuration in
            configuration.baseURL = URL(string: "https://api.example.com/v1")
            configuration.globalHeaders = ["Authorization": "Bearer TOKEN"]
        }

        let messages = LockedBox<[String]>([])
        let logger = NetworkingLogger { level, sanitizedMessage in
            messages.withLock {
                $0.append("[\(level)] \(sanitizedMessage)")
            }
        }
        logger.log(request: URLRequest(url: URL(string: "https://example.com")!))

        #expect(client.baseURL == URL(string: "https://api.example.com/v1"))
        #expect(client.globalHeaders == ["Authorization": "Bearer TOKEN"])
        #expect(messages.withLock { $0.count } == 1)
    }

    @Test("Empty-response sending and exhaustive error handling compile")
    func emptyResponseAndErrors() async throws {
        let stub = StubSession { request in
            .respond(try .http(for: request, statusCode: 204))
        }

        let response = try await stub.client().send(
            DocumentationDeleteUserRequest(userID: 42)
        )

        #expect(response == EmptyResponse())
        #expect(documentationMessage(for: .invalidURL) == "Invalid URL")
    }

    @Test("Response metadata, raw data, and final customization examples compile")
    func responseCapabilities() async throws {
        let capturedTimeout = LockedBox<TimeInterval?>(nil)
        let body = Data([0x01, 0x02, 0x03])
        let stub = StubSession { request in
            capturedTimeout.withLock { $0 = request.timeoutInterval }
            return .respond(try .http(
                for: request,
                headers: ["ETag": "avatar-42"],
                data: body
            ))
        }
        let client: any APIClientResponseProtocol = stub.client()

        let response = try await client.sendResponse(
            DocumentationRawRequest(userID: 42)
        )

        #expect(response.value == body)
        #expect(response.data == body)
        #expect(response.value(forHTTPHeaderField: "etag") == "avatar-42")
        #expect(capturedTimeout.withLock { $0 } == 120)

        let mock = MockAPIClient()
        await mock.stubResponse(
            DocumentationGetUserRequest.self,
            with: HTTPResponse(
                value: DocumentationUser(id: 42, displayName: "Arthur"),
                metadata: HTTPResponseMetadata(statusCode: 200)
            )
        )
        #expect(try await mock.sendResponse(
            DocumentationGetUserRequest(userID: 42)
        ).statusCode == 200)
    }

    @Test("Upload and download examples compile through the transfer protocol")
    func fileTransfers() async throws {
        let stub = StubSession { request in
            if request.url?.path.contains("avatar") == true {
                return .respond(try .http(
                    for: request,
                    data: Data(#"{"id":42,"displayName":"Arthur"}"#.utf8)
                ))
            }
            return .respond(try .http(
                for: request,
                data: Data("export".utf8)
            ))
        }
        let client: any APIClientTransferProtocol = stub.client()

        let upload = try await client.upload(
            DocumentationUploadAvatarRequest(userID: 42),
            from: .data(Data("image".utf8))
        )
        let download = try await client.download(
            DocumentationExportRequest(exportID: "latest")
        )
        defer { try? FileManager.default.removeItem(at: download.fileURL) }

        #expect(upload.value == DocumentationUser(id: 42, displayName: "Arthur"))
        #expect(try Data(contentsOf: download.fileURL) == Data("export".utf8))
    }

    @Test("WebSocket examples compile and run through protocol existentials")
    func webSockets() async throws {
        let mockConnection = MockWebSocketConnection(
            url: URL(string: "wss://example.com/rooms/lobby/socket")!,
            negotiatedSubprotocol: "chat.v1",
            incoming: [
                .success(.text("welcome")),
                .success(.binary(Data([0x01, 0x02])))
            ]
        )
        let mockClient = MockWebSocketClient(
            baseURL: URL(string: "https://example.com")
        )
        await mockClient.stub(
            DocumentationChatSocket.self,
            with: mockConnection
        )
        let client: any WebSocketClientProtocol = mockClient
        let connection = try await client.connect(
            DocumentationChatSocket(roomID: "lobby")
        )

        try await connection.send(text: "hello")
        let firstMessage = try await connection.receive()

        var streamedMessages: [WebSocketMessage] = []
        for try await message in connection.messages {
            streamedMessages.append(message)
            break
        }

        try await connection.ping()
        try await connection.close(code: .normalClosure, reason: "Done")

        #expect(connection.url == URL(string: "wss://example.com/rooms/lobby/socket"))
        #expect(connection.negotiatedSubprotocol == "chat.v1")
        #expect(firstMessage == .text("welcome"))
        #expect(streamedMessages == [.binary(Data([0x01, 0x02]))])
        #expect(await mockConnection.sentMessages == [.text("hello")])
        #expect(await mockConnection.pingCount == 1)
        #expect(await mockConnection.closeDetails == WebSocketClose(
            code: .normalClosure,
            reason: Data("Done".utf8)
        ))
        #expect(await mockClient.recordedRequests.map(\.path) == [
            "rooms/lobby/socket"
        ])
    }
}

private func documentationMessage(for error: NetworkError) -> String {
    switch error {
    case .invalidURL:
        return "Invalid URL"
    case .invalidResponse:
        return "Invalid response"
    case .encodingFailed:
        return "Encoding failed"
    case .requestConfigurationFailed:
        return "Request configuration failed"
    case .transport:
        return "Transport failed"
    case .requestFailed(let statusCode, _):
        return "HTTP \(statusCode)"
    case .emptyResponse(let statusCode):
        return "Empty HTTP \(statusCode)"
    case .decodingFailed:
        return "Decoding failed"
    case .fileOperationFailed:
        return "File operation failed"
    case .unknown:
        return "Unknown failure"
    }
}

private struct DocumentationUser: Codable, Equatable, Sendable {
    let id: Int
    let displayName: String
}

private struct DocumentationGetUserRequest: Request {
    typealias ReturnType = DocumentationUser

    let userID: Int
    var path: String { "users/\(userID)" }
}

private struct DocumentationCreateUserRequest: Request {
    typealias ReturnType = DocumentationUser

    struct Payload: Encodable, Sendable {
        let displayName: String
    }

    let payload: Payload
    let path = "users"
    let method = HTTPMethod.post
    var headers: [String: String]? {
        ["Content-Type": "application/json"]
    }

    func makeBody(using encoder: JSONEncoder) throws -> Data? {
        try encoder.encode(payload)
    }
}

private struct DocumentationListUsersRequest: PaginatedRequest {
    typealias ReturnType = DocumentationUser

    let page: Int
    let pageSize: Int
    let role: String
    let path = "users"
    var queryItems: [URLQueryItem]? {
        [URLQueryItem(name: "role", value: role)]
    }
}

private struct DocumentationDeleteUserRequest: Request {
    typealias ReturnType = EmptyResponse

    let userID: Int
    var path: String { "users/\(userID)" }
    let method = HTTPMethod.delete
}

private struct DocumentationRawRequest: RawDataRequest {
    let userID: Int
    var path: String { "users/\(userID)/avatar" }

    func customize(_ request: inout URLRequest) throws {
        request.timeoutInterval = 120
    }
}

private struct DocumentationUploadAvatarRequest: Request {
    typealias ReturnType = DocumentationUser

    let userID: Int
    var path: String { "users/\(userID)/avatar" }
    let method = HTTPMethod.put
    let headers: [String: String]? = ["Content-Type": "image/jpeg"]
}

private struct DocumentationExportRequest: DownloadRequest {
    let exportID: String
    var path: String { "exports/\(exportID)" }
}

private struct DocumentationUserService: Sendable {
    let client: any APIClientProtocol

    func user(id: Int) async throws -> DocumentationUser {
        try await client.send(DocumentationGetUserRequest(userID: id))
    }
}

private struct DocumentationChatSocket: WebSocketRequest {
    let roomID: String

    var path: String { "rooms/\(roomID)/socket" }
    var queryItems: [URLQueryItem]? {
        [URLQueryItem(name: "history", value: "10")]
    }
    var headers: [String: String]? {
        ["Authorization": "Bearer TOKEN"]
    }
    var subprotocols: [String] { ["chat.v1"] }
    var maximumMessageSize: Int? { 1_048_576 }
}
