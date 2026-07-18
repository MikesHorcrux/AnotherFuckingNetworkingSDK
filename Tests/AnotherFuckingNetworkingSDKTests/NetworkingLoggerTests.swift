import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("NetworkingLogger")
struct NetworkingLoggerTests {
    @Test("APIClient logging is opt-in and preserves request-response order")
    func clientIntegration() async throws {
        let messages = LockedBox<[(NetworkingLogger.Level, String)]>([])
        let logger = NetworkingLogger { level, message in
            messages.withLock { $0.append((level, message)) }
        }
        let body = Data(#"{"id":1,"displayName":"Test"}"#.utf8)
        let stub = StubSession { request in
            .respond(try .http(for: request, data: body))
        }

        _ = try await stub.client(logger: logger).send(GetUserRequest(id: 1))

        let captured = messages.withLock { $0 }
        #expect(captured.count == 2)
        #expect(captured[0].0 == .debug)
        #expect(captured[0].1.hasPrefix("Outgoing request:"))
        #expect(captured[1].0 == .info)
        #expect(captured[1].1.hasPrefix("Response 200"))
    }

    @Test("Headers, query values, URL credentials, and nested JSON are redacted")
    func comprehensiveRedaction() throws {
        let configuration = NetworkingLogger.Configuration(
            bodyPolicy: .redactedJSON(maximumBytes: 10_000)
        )
        let logger = NetworkingLogger(configuration: configuration) { _, _ in }
        var request = URLRequest(url: try #require(URL(
            string: "https://alice:correct-horse@example.com/reset/path-secret?token=url-secret&accessToken=camel-query-secret&client_secret=client-query-secret&id_token=id-query-secret&query=public#fragment-secret"
        )))
        request.httpMethod = "POST"
        request.setValue("Bearer header-secret", forHTTPHeaderField: "AUTHORIZATION")
        request.setValue("safe", forHTTPHeaderField: "X-Public")
        request.httpBody = Data(#"{"password":"body-secret","apiKey":"camel-body-secret","client_secret":"client-body-secret","profile":{"name":"Ford","token":"nested-secret"},"items":[{"secret":"array-secret"}]}"#.utf8)

        let command = logger.curlCommand(for: request)

        #expect(!command.contains("alice"))
        #expect(!command.contains("correct-horse"))
        #expect(!command.contains("url-secret"))
        #expect(!command.contains("path-secret"))
        #expect(!command.contains("camel-query-secret"))
        #expect(!command.contains("client-query-secret"))
        #expect(!command.contains("id-query-secret"))
        #expect(!command.contains("header-secret"))
        #expect(!command.contains("fragment-secret"))
        #expect(!command.contains("body-secret"))
        #expect(!command.contains("camel-body-secret"))
        #expect(!command.contains("client-body-secret"))
        #expect(!command.contains("nested-secret"))
        #expect(!command.contains("array-secret"))
        #expect(command.contains("Ford"))
        #expect(command.contains("safe"))
        #expect(command.contains("redacted"))
    }

    @Test("cURL values are POSIX quoted and headers are deterministic")
    func shellSafetyAndOrdering() throws {
        let logger = NetworkingLogger(
            configuration: .init(
                bodyPolicy: .redactedJSON(maximumBytes: 1_000),
                urlPathPolicy: .included
            )
        ) { _, _ in }
        var request = URLRequest(url: try #require(URL(
            string: "https://example.com/people/O'Brien"
        )))
        request.httpMethod = "PATCH"
        request.setValue("Zulu", forHTTPHeaderField: "Z-Last")
        request.setValue("O'Brien", forHTTPHeaderField: "A-First")
        request.httpBody = Data(#"{"name":"O'Brien"}"#.utf8)

        let command = logger.curlCommand(for: request)

        #expect(command.contains("'https://example.com/people/O'\\''Brien'"))
        #expect(command.contains("'A-First: O'\\''Brien'"))
        #expect(command.contains(#"O'\''Brien"#))
        let firstHeader = try #require(command.range(of: "A-First"))
        let lastHeader = try #require(command.range(of: "Z-Last"))
        #expect(firstHeader.lowerBound < lastHeader.lowerBound)
    }

    @Test("Invalid and oversized bodies never expose contents")
    func unsafeBodiesAreOmitted() {
        let logger = NetworkingLogger(
            configuration: .init(bodyPolicy: .redactedJSON(maximumBytes: 4))
        ) { _, _ in }
        var oversized = URLRequest(url: URL(string: "https://example.com")!)
        oversized.httpBody = Data("body-secret".utf8)

        let oversizedCommand = logger.curlCommand(for: oversized)

        #expect(!oversizedCommand.contains("body-secret"))
        #expect(oversizedCommand.contains("11 bytes"))

        let invalidLogger = NetworkingLogger(
            configuration: .init(bodyPolicy: .redactedJSON(maximumBytes: 100))
        ) { _, _ in }
        var invalid = URLRequest(url: URL(string: "https://example.com")!)
        invalid.httpBody = Data("not-json-secret".utf8)

        let invalidCommand = invalidLogger.curlCommand(for: invalid)

        #expect(!invalidCommand.contains("not-json-secret"))
        #expect(invalidCommand.contains("15 bytes"))
    }

    @Test("The default body policy never exposes valid JSON")
    func defaultBodyOmission() {
        let logger = NetworkingLogger { _, _ in }
        var request = URLRequest(url: URL(string: "https://example.com")!)
        request.httpBody = Data(#"{"value":"default-secret"}"#.utf8)

        let command = logger.curlCommand(for: request)

        #expect(!command.contains("default-secret"))
        #expect(command.contains("body omitted"))
        #expect(!command.contains("--data-binary"))
    }

    @Test("Streaming bodies are never consumed for logging")
    func streamingBodyOmission() {
        let logger = NetworkingLogger(
            configuration: .init(bodyPolicy: .redactedJSON(maximumBytes: 1_000))
        ) { _, _ in }
        var request = URLRequest(url: URL(string: "https://example.com")!)
        request.httpBodyStream = InputStream(data: Data("stream-secret".utf8))

        let command = logger.curlCommand(for: request)

        #expect(!command.contains("stream-secret"))
        #expect(command.contains("streaming body omitted"))
    }

    @Test("Response URLs and JSON bodies use the same redaction policy")
    func responseRedaction() throws {
        let messages = LockedBox<[String]>([])
        let logger = NetworkingLogger(
            configuration: .init(bodyPolicy: .redactedJSON(maximumBytes: 10_000))
        ) { _, message in
            messages.withLock { $0.append(message) }
        }
        let url = try #require(URL(
            string: "https://example.com/callback/path-secret?code=response-secret"
        ))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ))
        let data = Data(#"{"token":"body-secret","value":"safe"}"#.utf8)

        logger.log(response: response, data: data)

        let message = try #require(messages.withLock { $0.first })
        #expect(!message.contains("response-secret"))
        #expect(!message.contains("path-secret"))
        #expect(!message.contains("body-secret"))
        #expect(message.contains("safe"))
        #expect(message.contains("redacted"))
    }

    @Test("Concurrent logging emits every complete message")
    func concurrentLogging() async {
        let messages = LockedBox<[String]>([])
        let logger = NetworkingLogger { _, message in
            messages.withLock { $0.append(message) }
        }
        let request = URLRequest(url: URL(string: "https://example.com")!)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    logger.log(request: request)
                }
            }
        }

        #expect(messages.withLock { $0.count } == 100)
        #expect(messages.withLock { $0.allSatisfy { $0.hasPrefix("Outgoing request:") } })
    }
}
