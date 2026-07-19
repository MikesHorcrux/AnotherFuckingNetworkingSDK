import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK
@testable import AnotherFuckingNetworkingSDKTesting

@Suite("Performance regressions")
struct PerformanceRegressionTests {
    @Test("Large multipart forms retain exact framing")
    func largeMultipartForm() throws {
        var form = try MultipartFormData(boundary: "PerformanceBoundary")
        for index in 0..<1_000 {
            try form.append("value-\(index)\nnext", name: "field-\(index)")
        }

        let encoded = try form.encode()
        let suffix = Data("--PerformanceBoundary--\r\n".utf8)

        #expect(encoded.starts(with: Data("--PerformanceBoundary\r\n".utf8)))
        #expect(encoded.suffix(suffix.count) == suffix)
        #expect(encoded.range(of: Data("value-999\r\nnext".utf8)) != nil)
    }

    @Test("Large FIFO queues preserve order across compaction")
    func largeFIFOQueue() {
        var queue = FIFOQueue(Array(0..<10_000))

        for expected in 0..<10_000 {
            #expect(queue.popFirst() == expected)
        }
        #expect(queue.isEmpty)

        for value in 10_000..<20_000 {
            queue.append(value)
        }
        #expect(queue.count == 10_000)
        for expected in 10_000..<20_000 {
            #expect(queue.popFirst() == expected)
        }
        #expect(queue.isEmpty)
    }

    @Test("Long percent-encoded paths validate without scalar copies")
    func longPercentEncodedPath() throws {
        let path = String(repeating: "segment%2F", count: 2_000) + "tail"
        let request = LongEncodedPathRequest(path: path)
        let url = try #require(request.makeURL(
            baseURL: URL(string: "https://example.com/api")!
        ))

        #expect(url.absoluteString.hasSuffix(path))
    }
}

private struct LongEncodedPathRequest: HTTPRequest {
    let path: String
    let pathEncoding = RequestPathEncoding.percentEncoded
}
