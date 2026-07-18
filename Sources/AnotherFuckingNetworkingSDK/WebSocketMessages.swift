import Foundation

/// Errors raised while converting typed values to or from WebSocket messages.
public enum WebSocketMessageCodecError: LocalizedError, Equatable, Sendable {
    case encodingFailed
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "The typed WebSocket value could not be encoded."
        case .decodingFailed:
            return "The WebSocket message could not be decoded as the requested type."
        }
    }
}

/// Converts an application value into one complete WebSocket message and back.
///
/// Codecs are deliberately separate from the transport so products can use
/// JSON, a binary schema, or a protocol-specific envelope without changing
/// connection lifecycle, buffering, or cancellation behavior.
public protocol WebSocketMessageCodec: Sendable {
    associatedtype Value: Codable & Sendable

    func encode(_ value: Value) throws -> WebSocketMessage
    func decode(_ message: WebSocketMessage) throws -> Value
}

/// Selects the wire representation used by ``JSONWebSocketMessageCodec``.
public enum JSONWebSocketMessageEncoding: Sendable {
    case text
    case binary
}

/// A deterministic JSON codec for typed WebSocket messages.
///
/// Decoding accepts either text or binary JSON so a server can migrate wire
/// representation independently; encoding follows the configured mode.
public struct JSONWebSocketMessageCodec<Value: Codable & Sendable>:
    WebSocketMessageCodec,
    Sendable
{
    public let encoding: JSONWebSocketMessageEncoding

    public init(encoding: JSONWebSocketMessageEncoding = .text) {
        self.encoding = encoding
    }

    public func encode(_ value: Value) throws -> WebSocketMessage {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(value)
        } catch {
            throw WebSocketMessageCodecError.encodingFailed
        }

        switch encoding {
        case .text:
            guard let text = String(data: data, encoding: .utf8) else {
                throw WebSocketMessageCodecError.encodingFailed
            }
            return .text(text)
        case .binary:
            return .binary(data)
        }
    }

    public func decode(_ message: WebSocketMessage) throws -> Value {
        let data: Data
        switch message {
        case .text(let text):
            data = Data(text.utf8)
        case .binary(let binary):
            data = binary
        }

        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw WebSocketMessageCodecError.decodingFailed
        }
    }
}

/// A typed view over a connection's bounded WebSocket message sequence.
public struct WebSocketDecodedMessages<Codec: WebSocketMessageCodec>:
    AsyncSequence,
    Sendable
{
    public typealias Element = Codec.Value

    private let messages: WebSocketMessages
    private let codec: Codec

    fileprivate init(
        messages: WebSocketMessages,
        codec: Codec
    ) {
        self.messages = messages
        self.codec = codec
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            messages: messages.makeAsyncIterator(),
            codec: codec
        )
    }

    public struct AsyncIterator: AsyncIteratorProtocol, Sendable {
        private var messages: WebSocketMessages.Iterator
        private let codec: Codec

        fileprivate init(
            messages: WebSocketMessages.Iterator,
            codec: Codec
        ) {
            self.messages = messages
            self.codec = codec
        }

        public mutating func next() async throws -> Codec.Value? {
            guard let message = try await messages.next() else {
                return nil
            }
            return try codec.decode(message)
        }
    }
}

public extension WebSocketConnectionProtocol {
    /// Encodes and sends one typed value as a complete WebSocket message.
    func send<Codec: WebSocketMessageCodec>(
        _ value: Codec.Value,
        using codec: Codec
    ) async throws {
        try await send(codec.encode(value))
    }

    /// Receives and decodes one typed WebSocket value.
    func receive<Codec: WebSocketMessageCodec>(
        _: Codec.Value.Type,
        using codec: Codec
    ) async throws -> Codec.Value {
        try codec.decode(try await receive())
    }

    /// Returns a typed view while preserving the connection's bounded FIFO and
    /// normal/abnormal close behavior.
    func decodedMessages<Codec: WebSocketMessageCodec>(
        using codec: Codec
    ) -> WebSocketDecodedMessages<Codec> {
        WebSocketDecodedMessages(messages: messages, codec: codec)
    }
}
