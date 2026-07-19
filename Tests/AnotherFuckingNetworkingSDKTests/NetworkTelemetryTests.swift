import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

@Suite("Network telemetry")
struct NetworkTelemetryTests {
    @Test("Successful requests emit privacy-safe attempt and duration events")
    func successfulRequest() async throws {
        let events = LockedBox<[NetworkTelemetryEvent]>([])
        let stub = StubSession { request in
            .respond(try .http(
                for: request,
                data: Data(#"{"id":42,"displayName":"Arthur"}"#.utf8)
            ))
        }
        let client = stub.client(telemetry: NetworkTelemetry { event in
            events.withLock { $0.append(event) }
        })

        _ = try await client.send(GetUserRequest(id: 42))

        let captured = events.withLock { $0 }
        #expect(captured.map(\.phase) == [
            .started,
            .attemptStarted,
            .attemptCompleted,
            .succeeded
        ])
        #expect(Set(captured.map(\.operationID)).count == 1)
        #expect(captured[1].attempt == 1)
        #expect(captured[2].statusCode == 200)
        #expect(captured[2].bytesReceived ?? 0 > 0)
        #expect(captured[2].durationNanoseconds != nil)
        #expect(captured[3].durationNanoseconds != nil)
        #expect(captured.allSatisfy { $0.taskMetrics == nil })
    }

    @Test("Rejected HTTP responses classify failures without exposing payloads")
    func rejectedResponse() async throws {
        let events = LockedBox<[NetworkTelemetryEvent]>([])
        let stub = StubSession { request in
            .respond(try .http(
                for: request,
                statusCode: 503,
                data: Data("private body".utf8)
            ))
        }
        let client = stub.client(telemetry: NetworkTelemetry { event in
            events.withLock { $0.append(event) }
        })

        do {
            _ = try await client.send(GetUserRequest(id: 42))
            Issue.record("Expected the rejected response")
        } catch is NetworkError {
            // Expected.
        }

        let captured = events.withLock { $0 }
        #expect(captured.last?.phase == .failed)
        #expect(captured.last?.errorKind == .httpStatus)
        #expect(captured.dropLast().contains {
            $0.phase == .attemptFailed && $0.statusCode == 503
        })
        #expect(captured.allSatisfy { $0.bytesSent == nil })
    }

    @Test("Stream telemetry stays leased until EOF")
    func streamLifecycle() async throws {
        let events = LockedBox<[NetworkTelemetryEvent]>([])
        let stub = StubSession { request in
            .respond(try .http(
                for: request,
                data: Data("streamed".utf8)
            ))
        }
        let client = stub.client(telemetry: NetworkTelemetry { event in
            events.withLock { $0.append(event) }
        })

        let stream = try await client.stream(GetUserRequest(id: 42))
        #expect(events.withLock { $0.last?.phase } == .attemptCompleted)
        for try await _ in stream {}

        #expect(events.withLock { $0.last?.phase } == .succeeded)
        #expect(events.withLock { $0.last?.durationNanoseconds } != nil)
    }

    @Test("Transfer telemetry collects task metrics without progress callbacks")
    func transferTaskMetrics() async throws {
        let events = LockedBox<[NetworkTelemetryEvent]>([])
        let stub = StubSession { request in
            .respond(try .http(
                for: request,
                data: Data("uploaded".utf8)
            ))
        }
        let client = stub.client(telemetry: NetworkTelemetry { event in
            events.withLock { $0.append(event) }
        })

        _ = try await client.upload(
            TelemetryUploadRequest(),
            from: .data(Data("body".utf8))
        )

        let metrics = events.withLock { events in
            events.filter { $0.phase == .taskMetrics }
        }
        #expect(!metrics.isEmpty)
        #expect(metrics.allSatisfy { $0.taskMetrics != nil })
    }
}

private struct TelemetryUploadRequest: RawDataRequest {
    var path: String { "telemetry/upload" }
    var method: HTTPMethod { .post }
}
