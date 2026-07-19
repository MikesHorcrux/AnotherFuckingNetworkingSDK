import Foundation
import Testing
@testable import AnotherFuckingNetworkingSDK

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct StubResponse: Sendable {
        let response: URLResponse
        let data: Data

        static func http(
            for request: URLRequest,
            statusCode: Int = 200,
            headers: [String: String]? = nil,
            data: Data = Data()
        ) throws -> Self {
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ))
            return Self(response: response, data: data)
        }
    }

    enum Action: Sendable {
        case respond(StubResponse)
        case fail(any Error)
        case pending(
            onStart: @Sendable () -> Void,
            onStop: @Sendable () -> Void
        )
    }

    typealias Handler = @Sendable (URLRequest) throws -> Action

    static let registry = Registry()

    private let stopHandler = LockedBox<(@Sendable () -> Void)?>(nil)

    override class func canInit(with request: URLRequest) -> Bool {
        registry.handler(for: request) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.registry.handler(for: request) else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.unsupportedURL)
            )
            return
        }

        do {
            switch try handler(request) {
            case .respond(let stub):
                client?.urlProtocol(
                    self,
                    didReceive: stub.response,
                    cacheStoragePolicy: .notAllowed
                )
                if !stub.data.isEmpty {
                    client?.urlProtocol(self, didLoad: stub.data)
                }
                client?.urlProtocolDidFinishLoading(self)

            case .fail(let error):
                client?.urlProtocol(self, didFailWithError: error)

            case .pending(let onStart, let onStop):
                stopHandler.withLock { $0 = onStop }
                onStart()
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        let handler = stopHandler.withLock { handler -> (@Sendable () -> Void)? in
            defer { handler = nil }
            return handler
        }
        handler?()
    }
}

extension StubURLProtocol {
    final class Registry: @unchecked Sendable {
        private let handlers = LockedBox<[String: Handler]>([:])

        func register(host: String, handler: @escaping Handler) {
            handlers.withLock { $0[host] = handler }
        }

        func unregister(host: String) {
            handlers.withLock { $0.removeValue(forKey: host) }
        }

        func handler(for request: URLRequest) -> Handler? {
            guard let host = request.url?.host else { return nil }
            return handlers.withLock { $0[host] }
        }
    }
}

final class StubSession: @unchecked Sendable {
    let baseURL: URL
    let session: URLSession

    private let host: String

    init(handler: @escaping StubURLProtocol.Handler) {
        host = "test-\(UUID().uuidString.lowercased()).example"
        baseURL = URL(string: "https://\(host)")!

        StubURLProtocol.registry.register(host: host, handler: handler)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    deinit {
        StubURLProtocol.registry.unregister(host: host)
        session.invalidateAndCancel()
    }

    func client(
        baseURL: URL? = nil,
        globalHeaders: [String: String] = [:],
        encoderFactory: @escaping APIClient.EncoderFactory = { JSONEncoder() },
        decoderFactory: @escaping APIClient.DecoderFactory = { JSONDecoder() }
    ) -> APIClient {
        APIClient(
            baseURL: baseURL ?? self.baseURL,
            urlSession: session,
            globalHeaders: globalHeaders,
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func withLock<Result>(_ operation: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation(&value)
    }
}

actor AsyncSignal {
    private var isSignaled = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1_024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        guard count >= 0 else { return nil }
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }

    return data
}

struct TestUser: Codable, Equatable, Sendable {
    let id: Int
    let displayName: String
}

struct GetUserRequest: Request {
    typealias ReturnType = TestUser

    let id: Int
    var path: String { "users/\(id)" }
}

struct EmptyRequest: Request {
    typealias ReturnType = EmptyResponse
    let path: String
    var method: HTTPMethod { .delete }
}
