import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("Streaming multipart form data")
struct StreamingMultipartTests {
    @Test("Default boundaries are unique UUID-based values")
    func defaultBoundaryIsUnique() {
        let first = StreamingMultipartFormData()
        let second = StreamingMultipartFormData()

        #expect(first.boundary.hasPrefix("AFNSDK-STREAM-"))
        #expect(first.boundary != "AFNSDK-STREAM-(UUID().uuidString)")
        #expect(first.boundary != second.boundary)
        #expect(first.boundary.count == "AFNSDK-STREAM-".count + 36)
    }

    @Test("File-backed parts are written without materializing the source")
    func writesFileBackedParts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("afn-streaming-multipart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.bin")
        let destination = directory.appendingPathComponent("body.bin")
        let payload = Data(repeating: 0xA5, count: 128 * 1_024)
        try payload.write(to: source)

        var form = try StreamingMultipartFormData(boundary: "AFN-BOUNDARY")
        try form.append("hello", name: "message")
        try form.append(
            source,
            name: "archive",
            filename: "archive.bin",
            contentType: "application/octet-stream"
        )
        try form.write(to: destination)

        let body = try Data(contentsOf: destination)
        #expect(body.range(of: Data("hello".utf8)) != nil)
        #expect(body.range(of: payload) != nil)
        let closing = Data("--AFN-BOUNDARY--\r\n".utf8)
        #expect(body.suffix(closing.count) == closing)
        #expect(form.estimatedByteCount == Int64(body.count))
    }

    @Test("Boundary collisions spanning file chunks fail closed")
    func detectsCrossChunkCollision() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("afn-streaming-multipart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("source.bin")
        let destination = directory.appendingPathComponent("body.bin")
        var payload = Data(repeating: 0x2A, count: 65_536 - 5)
        payload.append(Data("--AFN-BOUNDARY".utf8))
        try payload.write(to: source)

        var form = try StreamingMultipartFormData(boundary: "AFN-BOUNDARY")
        try form.append(source, name: "file", filename: "source.bin")

        #expect(throws: MultipartEncodingError.boundaryCollision(partIndex: 0)) {
            try form.write(to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("Missing file sources remain typed")
    func missingSourceIsTyped() throws {
        var form = try StreamingMultipartFormData(boundary: "AFN-BOUNDARY")
        let missing = URL(fileURLWithPath: "/tmp/afn-missing-\(UUID().uuidString)")
        try form.append(missing, name: "file", filename: "missing.bin")

        #expect(throws: FileTransferError.sourceDoesNotExist(missing)) {
            try form.validateSources()
        }
    }
}
