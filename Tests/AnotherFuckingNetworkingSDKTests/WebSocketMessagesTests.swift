import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK
import AnotherFuckingNetworkingSDKTesting

@Suite("Typed WebSocket messages")
struct WebSocketMessagesTests {
    private struct Envelope: Codable, Equatable, Sendable {
        let event: String
        let sequence: Int
    }

    @Test("JSON codec uses deterministic text and binary representations")
    func jsonCodecRoundTrip() throws {
        let value = Envelope(event: "message", sequence: 7)
        let textCodec = JSONWebSocketMessageCodec<Envelope>()
        let text = try textCodec.encode(value)
        #expect(text == .text("{\"event\":\"message\",\"sequence\":7}"))
        #expect(try textCodec.decode(.binary(Data(textPayload))) == value)

        let binaryCodec = JSONWebSocketMessageCodec<Envelope>(encoding: .binary)
        let binary = try binaryCodec.encode(value)
        #expect(binary == .binary(Data(textPayload)))
        #expect(try binaryCodec.decode(.text("{\"event\":\"message\",\"sequence\":7}")) == value)
    }

    @Test("Malformed JSON is reported as a stable codec error")
    func malformedJSON() {
        let codec = JSONWebSocketMessageCodec<Envelope>()
        do {
            _ = try codec.decode(.text("not-json"))
            Issue.record("Expected decoding failure")
        } catch let error as WebSocketMessageCodecError {
            #expect(error == .decodingFailed)
        } catch {
            Issue.record("Expected codec error, got \(error)")
        }
    }

    @Test("Typed send, receive, and sequence preserve connection semantics")
    func typedConnectionHelpers() async throws {
        let first = Envelope(event: "first", sequence: 1)
        let second = Envelope(event: "second", sequence: 2)
        let codec = JSONWebSocketMessageCodec<Envelope>()
        let mock = MockWebSocketConnection()
        await mock.enqueueIncoming(try codec.encode(first))

        do {
            #expect(try await mock.receive(Envelope.self, using: codec) == first)
        } catch {
            Issue.record("typed receive failed: \(error)")
            return
        }
        do {
            try await mock.send(second, using: codec)
        } catch {
            Issue.record("typed send failed: \(error)")
            return
        }
        #expect(await mock.sentMessages == [try codec.encode(second)])

        await mock.enqueueIncoming(try codec.encode(second))
        var iterator = mock.decodedMessages(using: codec).makeAsyncIterator()
        do {
            #expect(try await iterator.next() == second)
        } catch {
            Issue.record("typed sequence failed: \(error)")
            return
        }
        await mock.finish(with: .normalClosure)
        do {
            #expect(try await iterator.next() == nil)
        } catch {
            Issue.record("typed sequence close failed: \(error)")
        }
    }

    private var textPayload: [UInt8] {
        Array("{\"event\":\"message\",\"sequence\":7}".utf8)
    }
}
