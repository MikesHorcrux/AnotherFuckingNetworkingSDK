import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("Server-Sent Events")
struct ServerSentEventsTests {
    @Test("Parser preserves fields and joins multiline data")
    func parsesFields() throws {
        var parser = ServerSentEventParser(maximumEventBytes: 512)
        let source = [
            ": keep-alive",
            "id: 42",
            "event: update",
            "retry: 1500",
            "data: first",
            "data: second",
            "",
            ""
        ].joined(separator: "\r\n")
        let events = try parser.append(Data(source.utf8))

        #expect(events == [ServerSentEvent(
            event: "update",
            id: "42",
            data: "first\nsecond",
            retryMilliseconds: 1_500
        )])
    }

    @Test("Parser emits a final unterminated event and ignores NUL IDs")
    func finishesUnterminatedEvent() throws {
        var parser = ServerSentEventParser()
        _ = try parser.append(Data("id: bad\0id\ndata: payload".utf8))
        #expect(try parser.finish() == [ServerSentEvent(data: "payload")])
    }

    @Test("Parser rejects invalid UTF-8, retry values, and oversized events")
    func rejectsInvalidInput() {
        var utf8Parser = ServerSentEventParser()
        #expect(throws: ServerSentEventError.invalidUTF8) {
            _ = try utf8Parser.append(Data([100, 97, 116, 97, 58, 255, 10]))
        }

        var retryParser = ServerSentEventParser()
        #expect(throws: ServerSentEventError.invalidRetryField) {
            _ = try retryParser.append(Data("retry: never\n".utf8))
        }

        var boundedParser = ServerSentEventParser(maximumEventBytes: 4)
        #expect(throws: ServerSentEventError.eventTooLarge(
            maximumBytes: 4,
            actualBytes: 5
        )) {
            _ = try boundedParser.append(Data("data: nope\n".utf8))
        }
    }

    @Test("Async event stream consumes the existing byte stream")
    func asyncStream() async throws {
        let stream = ServerSentEventStream(
            bytes: HTTPByteStream(
                data: Data("data: one\n\ndata: two\n\n".utf8),
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    url: URL(string: "https://example.com/events"),
                    headers: ["Content-Type": "text/event-stream"]
                )
            )
        )

        var events: [ServerSentEvent] = []
        for try await event in stream {
            events.append(event)
        }

        #expect(stream.statusCode == 200)
        #expect(stream.value(forHTTPHeaderField: "CONTENT-TYPE") == "text/event-stream")
        #expect(stream.headers["content-type"] == "text/event-stream")
        #expect(events == [
            ServerSentEvent(data: "one"),
            ServerSentEvent(data: "two")
        ])
    }
}
