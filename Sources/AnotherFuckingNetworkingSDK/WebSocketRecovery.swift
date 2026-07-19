import Foundation

/// Errors raised by the bounded WebSocket session-recovery stores.
public enum WebSocketRecoveryStoreError: LocalizedError, Equatable, Sendable {
    case invalidKey
    case payloadTooLarge(maximumBytes: Int, actualBytes: Int)
    case corruptDocument
    case encodingFailed
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "The WebSocket recovery key is empty or too long."
        case .payloadTooLarge(let maximumBytes, let actualBytes):
            return "The WebSocket recovery payload is too large: \(actualBytes) bytes; maximum is \(maximumBytes)."
        case .corruptDocument:
            return "The WebSocket recovery store contains invalid JSON."
        case .encodingFailed:
            return "The WebSocket recovery store could not encode its document."
        case .decodingFailed:
            return "The WebSocket recovery payload could not be decoded."
        }
    }
}

/// Opaque, bounded state that an application can use to resume a protocol
/// cursor or server session after a WebSocket reconnect.
public struct WebSocketRecoveryState: Codable, Equatable, Sendable {
    /// Maximum state retained for one connection key.
    public static let maximumPayloadBytes = 64 * 1_024

    public let payload: Data
    public let updatedAt: Date

    public init(
        payload: Data,
        updatedAt: Date = Date()
    ) throws {
        guard payload.count <= Self.maximumPayloadBytes else {
            throw WebSocketRecoveryStoreError.payloadTooLarge(
                maximumBytes: Self.maximumPayloadBytes,
                actualBytes: payload.count
            )
        }
        self.payload = payload
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case payload
        case updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            payload: try container.decode(Data.self, forKey: .payload),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt)
        )
    }
}

/// An async persistence boundary for opaque WebSocket recovery state.
public protocol WebSocketRecoveryStore: Sendable {
    func load(for key: String) async throws -> WebSocketRecoveryState?
    func save(
        _ state: WebSocketRecoveryState,
        for key: String
    ) async throws
    func remove(for key: String) async throws
}

/// Encodes application-owned recovery values into bounded state without
/// coupling the transport to a product protocol.
public protocol WebSocketRecoveryCodec: Sendable {
    associatedtype Value: Codable & Sendable

    func encode(_ value: Value) throws -> WebSocketRecoveryState
    func decode(_ state: WebSocketRecoveryState) throws -> Value
}

/// A deterministic JSON codec for typed WebSocket recovery values.
public struct JSONWebSocketRecoveryCodec<Value: Codable & Sendable>:
    WebSocketRecoveryCodec,
    Sendable
{
    public init() {}

    public func encode(_ value: Value) throws -> WebSocketRecoveryState {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(value)
        } catch {
            throw WebSocketRecoveryStoreError.encodingFailed
        }
        return try WebSocketRecoveryState(payload: data)
    }

    public func decode(_ state: WebSocketRecoveryState) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: state.payload)
        } catch {
            throw WebSocketRecoveryStoreError.decodingFailed
        }
    }
}

/// An actor-backed recovery store for tests, previews, and in-memory clients.
public actor InMemoryWebSocketRecoveryStore: WebSocketRecoveryStore {
    private var states: [String: WebSocketRecoveryState] = [:]

    public init() {}

    public func load(for key: String) async throws -> WebSocketRecoveryState? {
        try validateWebSocketRecoveryKey(key)
        return states[key]
    }

    public func save(
        _ state: WebSocketRecoveryState,
        for key: String
    ) async throws {
        try validateWebSocketRecoveryKey(key)
        states[key] = state
    }

    public func remove(for key: String) async throws {
        try validateWebSocketRecoveryKey(key)
        states.removeValue(forKey: key)
    }
}

/// An actor-backed JSON recovery store with atomic writes and a lazy cache.
public actor JSONWebSocketRecoveryStore: WebSocketRecoveryStore {
    private let fileURL: URL
    private let fileIOExecutor: FileIOExecutor
    private var cachedStates: [String: WebSocketRecoveryState]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        fileIOExecutor = .shared
    }

    public func load(for key: String) async throws -> WebSocketRecoveryState? {
        try validateWebSocketRecoveryKey(key)
        return try await loadCache()[key]
    }

    public func save(
        _ state: WebSocketRecoveryState,
        for key: String
    ) async throws {
        try validateWebSocketRecoveryKey(key)
        var updated = try await loadCache()
        updated[key] = state
        try await persist(updated)
        cachedStates = updated
    }

    public func remove(for key: String) async throws {
        try validateWebSocketRecoveryKey(key)
        var updated = try await loadCache()
        updated.removeValue(forKey: key)
        try await persist(updated)
        cachedStates = updated
    }

    private func loadCache() async throws
        -> [String: WebSocketRecoveryState] {
        if let cachedStates {
            return cachedStates
        }

        let url = fileURL
        let loaded = try await fileIOExecutor.run {
            () throws -> [String: WebSocketRecoveryState] in
            guard FileManager.default.fileExists(atPath: url.path) else {
                return [:]
            }
            do {
                return try JSONDecoder().decode(
                    [String: WebSocketRecoveryState].self,
                    from: Data(contentsOf: url)
                )
            } catch let error as WebSocketRecoveryStoreError {
                throw error
            } catch {
                throw WebSocketRecoveryStoreError.corruptDocument
            }
        }
        for key in loaded.keys {
            try validateWebSocketRecoveryKey(key)
        }
        cachedStates = loaded
        return loaded
    }

    private func persist(
        _ states: [String: WebSocketRecoveryState]
    ) async throws {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(states)
        } catch {
            throw WebSocketRecoveryStoreError.encodingFailed
        }

        let url = fileURL
        try await fileIOExecutor.runCommitted {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
    }
}

/// Connects a recovery store to the reliability wrapper's contextual
/// restoration hook without imposing a wire format on the application.
public struct WebSocketRecoveryAdapter: Sendable {
    public typealias RestoreHandler = @Sendable (
        any WebSocketConnectionProtocol,
        WebSocketReconnectContext,
        WebSocketRecoveryState?
    ) async throws -> Void

    private let store: any WebSocketRecoveryStore
    private let key: String
    private let restoreHandler: RestoreHandler

    public init(
        store: any WebSocketRecoveryStore,
        key: String,
        restore: @escaping RestoreHandler
    ) throws {
        try validateWebSocketRecoveryKey(key)
        self.store = store
        self.key = key
        restoreHandler = restore
    }

    /// Loads the latest opaque state and invokes the application protocol
    /// handler after a replacement handshake succeeds.
    public func restore(
        _ connection: any WebSocketConnectionProtocol,
        context: WebSocketReconnectContext
    ) async throws {
        try await restoreHandler(
            connection,
            context,
            try await store.load(for: key)
        )
    }

    /// A closure suitable for `restorerWithContext:`.
    public var restorerWithContext: WebSocketSessionRestorerWithContext {
        { connection, context in
            try await restore(connection, context: context)
        }
    }

    public func save(_ state: WebSocketRecoveryState) async throws {
        try await store.save(state, for: key)
    }

    public func remove() async throws {
        try await store.remove(for: key)
    }
}

/// A typed recovery adapter for applications whose checkpoint is `Codable`.
public struct JSONWebSocketRecoveryAdapter<Value: Codable & Sendable>: Sendable {
    private let adapter: WebSocketRecoveryAdapter
    private let codec: JSONWebSocketRecoveryCodec<Value>

    public init(
        store: any WebSocketRecoveryStore,
        key: String,
        restore: @escaping @Sendable (
            any WebSocketConnectionProtocol,
            WebSocketReconnectContext,
            Value?
        ) async throws -> Void
    ) throws {
        let codec = JSONWebSocketRecoveryCodec<Value>()
        self.codec = codec
        self.adapter = try WebSocketRecoveryAdapter(
            store: store,
            key: key
        ) { connection, context, state in
            try await restore(
                connection,
                context,
                try state.map(codec.decode)
            )
        }
    }

    public var restorerWithContext: WebSocketSessionRestorerWithContext {
        adapter.restorerWithContext
    }

    public func restore(
        _ connection: any WebSocketConnectionProtocol,
        context: WebSocketReconnectContext
    ) async throws {
        try await adapter.restore(connection, context: context)
    }

    public func save(_ value: Value) async throws {
        try await adapter.save(codec.encode(value))
    }

    public func remove() async throws {
        try await adapter.remove()
    }
}

private func validateWebSocketRecoveryKey(_ key: String) throws {
    guard !key.isEmpty, key.utf8.count <= 256 else {
        throw WebSocketRecoveryStoreError.invalidKey
    }
}
