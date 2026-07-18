import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("Multipart form data")
struct MultipartFormDataTests {
    @Test("Mixed text and file parts use exact CRLF framing")
    func exactMixedBody() throws {
        var form = try MultipartFormData(boundary: "Boundary-123")
        try form.append("Arthur", name: "display_name")
        try form.append(
            Data([0xFF, 0xD8, 0xFF]),
            name: "avatar",
            filename: "avatar.jpg",
            contentType: "image/jpeg"
        )

        let prefix = "--Boundary-123\r\n"
            + "Content-Disposition: form-data; name=\"display_name\"\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "\r\nArthur\r\n"
            + "--Boundary-123\r\n"
            + "Content-Disposition: form-data; name=\"avatar\"; "
            + "filename=\"avatar.jpg\"\r\n"
            + "Content-Type: image/jpeg\r\n\r\n"
        var expected = Data(prefix.utf8)
        expected.append(Data([0xFF, 0xD8, 0xFF]))
        expected.append(Data("\r\n--Boundary-123--\r\n".utf8))

        #expect(try form.encode() == expected)
        #expect(
            form.contentType
                == "multipart/form-data; boundary=\"Boundary-123\""
        )
    }

    @Test("Binary payloads remain exact and optional part headers are honored")
    func binaryFidelityAndContentTypeDefaults() throws {
        let raw = Data([0x00, 0xFF, 0x0D, 0x0A])
        var form = try MultipartFormData(boundary: "BinaryBoundary")
        try form.append(raw, name: "raw")
        try form.append(
            Data(),
            name: "file",
            filename: "empty.bin"
        )

        var expected = Data(
            (
                "--BinaryBoundary\r\n"
                    + "Content-Disposition: form-data; name=\"raw\"\r\n"
                    + "\r\n"
            ).utf8
        )
        expected.append(raw)
        let suffix = "\r\n--BinaryBoundary\r\n"
            + "Content-Disposition: form-data; name=\"file\"; "
            + "filename=\"empty.bin\"\r\n"
            + "Content-Type: application/octet-stream\r\n"
            + "\r\n\r\n--BinaryBoundary--\r\n"
        expected.append(Data(suffix.utf8))

        #expect(try form.encode() == expected)
    }

    @Test("Text line endings are normalized without changing Unicode")
    func textLineEndings() throws {
        var form = try MultipartFormData(boundary: "TextBoundary")
        try form.append("one\ntwo\rthree\r\nfour 🪐", name: "text")

        let expected = "--TextBoundary\r\n"
            + "Content-Disposition: form-data; name=\"text\"\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "\r\none\r\ntwo\r\nthree\r\nfour 🪐\r\n"
            + "--TextBoundary--\r\n"
        #expect(try form.encode() == Data(expected.utf8))
    }

    @Test("Duplicate names preserve insertion order")
    func duplicateNamesAndOrder() throws {
        var form = try MultipartFormData(boundary: "OrderBoundary")
        try form.append("first", name: "value")
        try form.append(Data("second".utf8), name: "value")
        try form.append("third", name: "value")

        let body = try #require(String(data: form.encode(), encoding: .utf8))
        let first = try #require(body.range(of: "first"))
        let second = try #require(body.range(of: "second"))
        let third = try #require(body.range(of: "third"))
        #expect(first.lowerBound < second.lowerBound)
        #expect(second.lowerBound < third.lowerBound)
        #expect(body.components(separatedBy: "name=\"value\"").count - 1 == 3)
    }

    @Test("Quoted disposition parameters escape quote and backslash")
    func quotedParameterEscaping() throws {
        var form = try MultipartFormData(boundary: "EscapingBoundary")
        try form.append(
            Data("body".utf8),
            name: "field\"\\name",
            filename: "a\"\\b.txt",
            contentType: "text/plain"
        )

        let body = try #require(String(data: form.encode(), encoding: .utf8))
        #expect(body.contains(
            "name=\"field\\\"\\\\name\"; filename=\"a\\\"\\\\b.txt\""
        ))
    }

    @Test("Invalid names and filenames are rejected without mutation")
    func dispositionValidationIsAtomic() throws {
        let invalidValues = [
            "", "line\nbreak", "carriage\rreturn", "tab\t", "nul\0",
            "delete\u{7F}", "café"
        ]

        for value in invalidValues {
            var nameForm = try MultipartFormData(boundary: "NameBoundary")
            do {
                try nameForm.append("value", name: value)
                Issue.record("Expected invalid field name: \(String(reflecting: value))")
            } catch let error as MultipartEncodingError {
                #expect(error == .invalidName(value))
            }

            var filenameForm = try MultipartFormData(boundary: "FileBoundary")
            do {
                try filenameForm.append(
                    Data(),
                    name: "file",
                    filename: value
                )
                Issue.record("Expected invalid filename: \(String(reflecting: value))")
            } catch let error as MultipartEncodingError {
                #expect(error == .invalidFilename(value))
            }
        }

        var form = try MultipartFormData(boundary: "AtomicBoundary")
        try form.append("before", name: "valid")
        let before = try form.encode()
        #expect(throws: MultipartEncodingError.invalidName("bad\nname")) {
            try form.append("ignored", name: "bad\nname")
        }
        #expect(try form.encode() == before)
        #expect(throws: MultipartEncodingError.invalidFilename("bad\rfile")) {
            try form.append(
                Data(),
                name: "valid",
                filename: "bad\rfile"
            )
        }
        #expect(try form.encode() == before)
        #expect(
            throws: MultipartEncodingError.invalidContentType(
                "text/plain; charset=utf-8"
            )
        ) {
            try form.append(
                Data(),
                name: "valid",
                contentType: "text/plain; charset=utf-8"
            )
        }
        #expect(try form.encode() == before)
    }

    @Test("Boundary grammar accepts every edge and rejects invalid values")
    func boundaryValidation() throws {
        let valid = [
            "A",
            String(repeating: "a", count: 70),
            "A B",
            "AZaz09'()+_,-./:=?"
        ]
        for boundary in valid {
            let form = try MultipartFormData(boundary: boundary)
            #expect(form.boundary == boundary)
        }

        let invalid = [
            "",
            String(repeating: "a", count: 71),
            "trailing ",
            "bad\tboundary",
            "bad\"boundary",
            "bad;boundary",
            "bøundary"
        ]
        for boundary in invalid {
            do {
                _ = try MultipartFormData(boundary: boundary)
                Issue.record("Expected invalid boundary: \(boundary)")
            } catch let error as MultipartEncodingError {
                #expect(error == .invalidBoundary(boundary))
            }
        }
    }

    @Test("Content types are restricted to one concrete bare type and subtype")
    func contentTypeValidation() throws {
        for contentType in [
            "text/plain",
            "application/octet-stream",
            "application/vnd.example+json",
            "x-custom/x.value"
        ] {
            var form = try MultipartFormData(boundary: "MediaBoundary")
            try form.append(Data(), name: "value", contentType: contentType)
        }

        let invalid = [
            "", "*/*", "text/*", "/json", "text/", "text/plain/extra",
            "text/plain; charset=utf-8", "text /plain", "text/pläin",
            "text/plain\r\nX-Injected: yes"
        ]
        for contentType in invalid {
            var form = try MultipartFormData(boundary: "MediaBoundary")
            do {
                try form.append(Data(), name: "value", contentType: contentType)
                Issue.record("Expected invalid content type: \(contentType)")
            } catch let error as MultipartEncodingError {
                #expect(error == .invalidContentType(contentType))
            }
        }
    }

    @Test("Empty forms and payload boundary collisions fail explicitly")
    func emptyAndCollisionFailures() throws {
        let empty = try MultipartFormData(boundary: "CollisionBoundary")
        #expect(throws: MultipartEncodingError.emptyForm) {
            try empty.encode()
        }

        var form = try MultipartFormData(boundary: "CollisionBoundary")
        try form.append(Data("safe".utf8), name: "first")
        try form.append(
            Data("before--CollisionBoundary-after".utf8),
            name: "second"
        )
        #expect(throws: MultipartEncodingError.boundaryCollision(partIndex: 1)) {
            try form.encode()
        }
    }

    @Test("Encoding and copied values are deterministic")
    func valueDeterminism() throws {
        var form = try MultipartFormData(boundary: "StableBoundary")
        try form.append("value", name: "field")
        let copy = form

        #expect(try form.encode() == form.encode())
        #expect(try form.encode() == copy.encode())
    }

    @Test("Generated boundaries are valid, quoted, stable, and Sendable")
    func generatedBoundaryAndSendable() throws {
        var form = MultipartFormData()
        try form.append("value", name: "field")
        requireSendable(form)

        #expect((1...70).contains(form.boundary.utf8.count))
        _ = try MultipartFormData(boundary: form.boundary)
        #expect(
            form.contentType
                == "multipart/form-data; boundary=\"\(form.boundary)\""
        )
        #expect(try form.encode() == form.encode())
    }

    @Test("Encoded forms plug into data-backed upload tasks")
    func uploadIntegration() async throws {
        let captured = LockedBox<URLRequest?>(nil)
        let stub = StubSession { request in
            captured.withLock { $0 = request }
            return .respond(try .http(for: request, statusCode: 204))
        }
        var form = try MultipartFormData(boundary: "UploadBoundary")
        try form.append("value", name: "field")
        let body = try form.encode()

        let response = try await stub.client().upload(
            MultipartUploadRequest(contentType: form.contentType),
            from: .data(body)
        )

        let request = try #require(captured.withLock { $0 })
        #expect(request.value(forHTTPHeaderField: "Content-Type") == form.contentType)
        #expect(requestBodyData(request) == body)
        #expect(response.value == EmptyResponse())
    }
}

private struct MultipartUploadRequest: Request {
    typealias ReturnType = EmptyResponse

    let contentType: String
    let path = "multipart"
    let method = HTTPMethod.post
    var headers: [String: String]? {
        ["Content-Type": contentType]
    }
}

private func requireSendable<T: Sendable>(_ value: T) {}
