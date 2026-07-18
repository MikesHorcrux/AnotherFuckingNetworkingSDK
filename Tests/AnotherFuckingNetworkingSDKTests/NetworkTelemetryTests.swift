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
        #expect(captured.map(\.phase).filter { $0 != .taskMetrics } == [
            .started,
            .attemptStarted,
            .attemptCompleted,
            .succeeded
        ])
        #expect(Set(captured.map(\.operationID)).count == 1)
        let attemptStarted = captured.first { $0.phase == .attemptStarted }
        let attemptCompleted = captured.first { $0.phase == .attemptCompleted }
        #expect(attemptStarted?.attempt == 1)
        #expect(attemptCompleted?.statusCode == 200)
        #expect(attemptCompleted?.bytesReceived ?? 0 > 0)
        #expect(attemptCompleted?.durationNanoseconds != nil)
        #expect(captured.last?.durationNanoseconds != nil)
        let metrics = captured.filter { $0.phase == .taskMetrics }
        #expect(metrics.count == 1)
        #expect(metrics.first?.attempt == 1)
        #expect(metrics.first?.taskMetrics != nil)
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
        let metrics = events.withLock { events in
            events.filter { $0.phase == .taskMetrics }
        }
        #expect(metrics.count == 1)
        #expect(metrics.first?.attempt == 1)
        #expect(metrics.first?.taskMetrics != nil)
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
