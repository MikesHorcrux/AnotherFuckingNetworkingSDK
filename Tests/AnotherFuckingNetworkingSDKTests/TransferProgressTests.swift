import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("Transfer progress")
struct TransferProgressTests {
    @Test("Progress values clamp counts and expose known fractions")
    func progressValue() {
        let event = TransferProgress(
            operation: .upload,
            phase: .running,
            bytesCompleted: -4,
            totalBytes: 200,
            attempt: 0
        )

        #expect(event.bytesCompleted == 0)
        #expect(event.totalBytes == 200)
        #expect(event.attempt == 1)
        #expect(event.fractionCompleted == 0)
        #expect(TransferProgress(
            operation: .download,
            phase: .running,
            bytesCompleted: 4,
            totalBytes: nil
        ).fractionCompleted == nil)
    }

    @Test("Uploads report lifecycle progress without changing the response")
    func uploadProgress() async throws {
        let body = Data("payload".utf8)
        let stub = StubSession { request in
            .respond(try .http(for: request, data: Data("ok".utf8)))
        }
        let events = LockedBox<[TransferProgress]>([])
        let client: any APIClientTransferProgressProtocol = stub.client()

        let response = try await client.upload(
            RawUploadRequest(),
            from: .data(body),
            progress: { event in
                events.withLock { $0.append(event) }
            }
        )

        #expect(response.value == Data("ok".utf8))
        let captured = events.withLock { $0 }
        #expect(captured.first?.phase == .started)
        #expect(captured.last?.phase == .completed)
        #expect(captured.last?.bytesCompleted == Int64(body.count))
        #expect(captured.last?.fractionCompleted == 1)
    }

    @Test("Downloads report completion after the file commit")
    func downloadProgress() async throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("afn-progress-\(UUID().uuidString)")
        let body = Data("download".utf8)
        try body.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let events = LockedBox<[TransferProgress]>([])
        let client = StubSession { request in
            .respond(try .http(for: request))
        }.client(downloadOperation: { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(body.count)]
            ))
            return (source, response)
        })

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("afn-progress-destination-\(UUID().uuidString)")
        let response = try await client.download(
            ProgressDownloadRequest(),
            to: .file(destination, overwriteExisting: false),
            progress: { event in
                events.withLock { $0.append(event) }
            }
        )
        defer { try? FileManager.default.removeItem(at: response.fileURL) }

        let captured = events.withLock { $0 }
        #expect(captured.map(\.phase) == [.started, .completed])
        #expect(captured.last?.bytesCompleted == Int64(body.count))
        #expect(captured.last?.fractionCompleted == 1)
        #expect(try Data(contentsOf: response.fileURL) == body)
    }
}

private struct RawUploadRequest: RawDataRequest {
    let path = "upload"
    let method = HTTPMethod.post
}

private struct ProgressDownloadRequest: DownloadRequest {
    let path = "download"
}
