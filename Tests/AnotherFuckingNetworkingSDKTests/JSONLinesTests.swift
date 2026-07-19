import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("JSON Lines streaming")
struct JSONLinesTests {
    @Test("Parser decodes CRLF records and ignores blank lines")
    func parsesRecords() throws {
        var parser = JSONLinesParser<Record>(maximumLineBytes: 512)
        let wire = [
            "{\"cursor\":\"one\",\"count\":1}",
            "",
            "{\"cursor\":\"two\",\"count\":2}",
            ""
        ].joined(separator: "\r\n")

        let records = try parser.append(Data(wire.utf8))
        #expect(records == [
            Record(cursor: "one", count: 1),
            Record(cursor: "two", count: 2)
        ])
    }

    @Test("Parser decodes a final unterminated record")
    func finalRecord() throws {
        var parser = JSONLinesParser<Record>()
        _ = try parser.append(Data("{\"cursor\":\"last\",\"count\":3}".utf8))
        #expect(try parser.finish() == [Record(cursor: "last", count: 3)])
    }

    @Test("Parser bounds lines and hides decoder details")
    func rejectsInvalidInput() {
        var bounded = JSONLinesParser<Record>(maximumLineBytes: 4)
        #expect(throws: JSONLinesError.lineTooLarge(
            maximumBytes: 4,
            actualBytes: 5
        )) {
            _ = try bounded.append(Data("12345".utf8))
        }

        var invalid = JSONLinesParser<Record>()
        #expect(throws: JSONLinesError.decodingFailed) {
            _ = try invalid.append(Data("not-json\n".utf8))
        }
    }

    @Test("Async JSON Lines stream is single-pass and exposes metadata")
    func asyncStream() async throws {
        let stream = JSONLinesStream<Record>(
            bytes: HTTPByteStream(
                data: Data("{\"cursor\":\"one\",\"count\":1}\n{\"cursor\":\"two\",\"count\":2}\n".utf8),
                metadata: HTTPResponseMetadata(
                    statusCode: 200,
                    url: URL(string: "https://example.com/records"),
                    headers: ["Content-Type": "application/x-ndjson"]
                )
            )
        )

        var records: [Record] = []
        for try await record in stream {
            records.append(record)
        }

        #expect(stream.statusCode == 200)
        #expect(stream.value(forHTTPHeaderField: "content-type") ==
            "application/x-ndjson")
        #expect(records == [
            Record(cursor: "one", count: 1),
            Record(cursor: "two", count: 2)
        ])
    }
}

private struct Record: Codable, Equatable, Sendable {
    let cursor: String
    let count: Int
}
