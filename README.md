# AnotherFuckingNetworkingSDK

A small, zero-dependency networking package for Swift 6. It provides typed requests, async URLSession transport, WebSockets, memory- and file-backed uploads, disk-backed downloads, response metadata and raw payloads, page-number pagination, explicit empty responses, bounded activity observation, safe opt-in diagnostics, and a separate actor-based testing library.

## Requirements

- Swift 6.0 or newer
- iOS 15 or newer
- macOS 12 or newer

## Installation

Add the package and core product to your target:

```swift
dependencies: [
    .package(
        url: "https://github.com/MikesHorcrux/AnotherFuckingNetworkingSDK.git",
        from: "2.0.0"
    )
]
```

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(
            name: "AnotherFuckingNetworkingSDK",
            package: "AnotherFuckingNetworkingSDK"
        )
    ]
)
```

Version 2.0 is the next intended release. Until it is tagged, pin a commit or use the branch containing these changes.

## Define a request

Response and request values are `Sendable`, so they can move safely across Swift concurrency boundaries.

```swift
import Foundation
import AnotherFuckingNetworkingSDK

struct User: Decodable, Sendable {
    let id: Int
    let displayName: String
}

struct GetUserRequest: Request {
    typealias ReturnType = User

    let userID: Int
    var path: String { "users/\(userID)" }
}
```

Create an injected client and send the request:

```swift
let client = APIClient(
    baseURL: URL(string: "https://api.example.com/v1")!,
    globalHeaders: ["Authorization": "Bearer TOKEN"]
)

let user = try await client.send(GetUserRequest(userID: 42))
```

An app can still configure `APIClient.shared`. Use `updateConfiguration` when changing multiple values so every request observes one atomic snapshot:

```swift
APIClient.shared.updateConfiguration { configuration in
    configuration.baseURL = URL(string: "https://api.example.com/v1")
    configuration.globalHeaders = ["Authorization": "Bearer TOKEN"]
}
```

Injected clients are recommended for services and tests because their configuration and ownership are explicit.

## Methods, queries, headers, and bodies

`Request` defaults to `GET` with no query items, headers, or body. Request headers override client headers case-insensitively.

```swift
struct SearchUsersRequest: Request {
    typealias ReturnType = [User]

    let query: String
    var path: String { "users/search" }
    var queryItems: [URLQueryItem]? {
        [URLQueryItem(name: "q", value: query)]
    }
    var headers: [String: String]? {
        ["Accept": "application/json"]
    }
}
```

Paths are decoded text by default and are percent encoded by the SDK. If an endpoint already supplies a percent-encoded path, return `.percentEncoded` from `pathEncoding` so escape sequences such as `%2F` are preserved.

For an encoded body, implement `makeBody(using:)`. The client supplies a fresh encoder for every request.

```swift
struct CreateUserRequest: Request {
    typealias ReturnType = User

    struct Payload: Encodable, Sendable {
        let displayName: String
    }

    let payload: Payload
    var path: String { "users" }
    var method: HTTPMethod { .post }
    var headers: [String: String]? {
        ["Content-Type": "application/json"]
    }

    func makeBody(using encoder: JSONEncoder) throws -> Data? {
        try encoder.encode(payload)
    }
}
```

Pre-encoded `Data` remains supported through the `body` property.

### Final request customization

Implement `customize(_:)` when an endpoint needs options from `URLRequest` that are intentionally outside the common request surface. The hook runs after the SDK has resolved the URL, merged headers, selected the method, and encoded the body.

```swift
struct SlowReportRequest: Request {
    typealias ReturnType = Report

    let path = "reports/annual"

    func customize(_ request: inout URLRequest) throws {
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.allowsCellularAccess = false
    }
}
```

This is also the right place for request signing that must inspect the final method, URL, headers, and body. A thrown error becomes `NetworkError.requestConfigurationFailed`; cancellation remains `CancellationError`.

## Configurable encoding and decoding

Factories avoid sharing mutable encoder or decoder instances between concurrent requests:

```swift
let client = APIClient(
    baseURL: URL(string: "https://api.example.com")!,
    encoderFactory: {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    },
    decoderFactory: {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
)
```

A request can override `decode(_:response:using:)` when an endpoint needs nonstandard decoding. A `PaginatedRequest` can similarly override `decodePage(_:response:using:)` for a nonstandard page envelope.

`ReturnType` only needs to be `Sendable`. The SDK supplies JSON decoding automatically when it is also `Decodable`; a request returning another kind of value implements `decode(_:response:using:)` itself.

## Response metadata and raw payloads

Use `sendResponse(_:)` when status, response headers, the final URL, or the original response bytes matter:

```swift
let response = try await client.sendResponse(GetUserRequest(userID: 42))

print(response.value)
print(response.statusCode)
print(response.value(forHTTPHeaderField: "ETag") ?? "no tag")
print(response.data.count)
```

Response header names are stored lowercase and looked up case-insensitively. The ordinary `send(_:)` API remains the concise choice when only the decoded value is needed. Metadata-aware services can depend on `any APIClientResponseProtocol`; ordinary services can continue using `any APIClientProtocol`.

For binary or otherwise undecoded bodies, conform to `RawDataRequest`:

```swift
struct DownloadAvatarRequest: RawDataRequest {
    let userID: Int
    var path: String { "users/\(userID)/avatar" }
}

let imageData = try await client.send(
    DownloadAvatarRequest(userID: 42)
)
```

`RawDataRequest` returns the response bytes exactly and accepts successful empty bodies as `Data()`.

## Uploads and downloads

`APIClient` uses URLSession upload tasks for both in-memory data and files. The upload response is decoded like an ordinary request and includes HTTP metadata:

```swift
struct UploadAvatarRequest: Request {
    typealias ReturnType = User

    let userID: Int
    var path: String { "users/\(userID)/avatar" }
    var method: HTTPMethod { .put }
    var headers: [String: String]? {
        ["Content-Type": "image/jpeg"]
    }
}

let response = try await client.upload(
    UploadAvatarRequest(userID: 42),
    from: .file(localImageURL)
)
```

Use `.data(payload)` for bytes already in memory. The supplied upload body replaces `Request.body` and bypasses `makeBody(using:)`. Data uploads expose those bytes to `customize(_:)` for signing; file uploads remain file-backed and do not copy their contents into the prepared `URLRequest`.

### Multipart form data

Build a multipart body, pass its content type through the request, and upload the encoded bytes:

```swift
struct UploadProfileRequest: Request {
    typealias ReturnType = User

    let userID: Int
    let contentType: String

    var path: String { "users/\(userID)/profile" }
    var method: HTTPMethod { .post }
    var headers: [String: String]? {
        ["Content-Type": contentType]
    }
}

var form = MultipartFormData()
try form.append("Arthur Dent", name: "displayName")
try form.append(
    imageData,
    name: "avatar",
    filename: "avatar.jpg",
    contentType: "image/jpeg"
)

let response = try await client.upload(
    UploadProfileRequest(userID: 42, contentType: form.contentType),
    from: .data(try form.encode())
)
```

`MultipartFormData` is deliberately memory-backed: every part and the final encoded body must fit in memory. Use the file-backed upload API for a large raw file; multipart streaming and background multipart uploads are separate lifecycle concerns. Text values are UTF-8 and their line endings are normalized to CRLF. Field names and filenames must be nonempty printable US-ASCII, and explicit content types must be bare `type/subtype` values without parameters.

The default initializer generates a boundary. The throwing `init(boundary:)` is intended for protocols or deterministic tests that require an explicit value: boundaries must contain 1–70 allowed MIME boundary characters and cannot end in a space. `encode()` rejects an empty form or a part containing `--<boundary>` instead of emitting ambiguous framing.

Downloads use the shared `HTTPRequest` construction surface without requiring an unused decoded response type:

```swift
struct ExportRequest: DownloadRequest {
    let exportID: String
    var path: String { "exports/\(exportID)" }
}

let download = try await client.download(ExportRequest(exportID: "latest"))
defer { try? FileManager.default.removeItem(at: download.fileURL) }

print(download.fileURL)
print(download.statusCode)
```

The default moves Foundation's ephemeral download into a unique SDK-owned temporary location before returning; the caller owns that file and removes it when finished. To choose the final location, pass `.file(destinationURL, overwriteExisting: false)`. Existing files are preserved unless overwrite is explicitly `true`, and file-location failures are reported as `NetworkError.fileOperationFailed` with a `FileTransferError` when the problem is caller-correctable.

Successful downloads are never loaded into memory. HTTP failure bodies are included in `NetworkError.requestFailed` only when they are at most 1 MiB; larger download error files produce `data == nil`.

Filesystem validation, bounded error reads, directory creation, moves, and
replacements run on a dedicated utility queue rather than occupying Swift's
cooperative executor. Cancellation observed before queued work begins prevents
the filesystem call. Once an individual move or replacement has started, the
system call is allowed to reach a consistent result; cancellation is reported
at the next completion boundary, so callers should still treat destination
ownership and cleanup as their responsibility.

These APIs model foreground async transfers. Delegate-owned progress reporting, resumable downloads, and relaunch-safe background sessions require application lifecycle policy and are intentionally separate concerns.

## WebSockets

`APIClient` opens WebSockets with the same base URL, global headers, cookies, authentication handling, and `URLSession` as ordinary requests. An `https` base URL becomes `wss`; `http` becomes `ws`.

```swift
struct ChatSocket: WebSocketRequest {
    let roomID: String

    var path: String { "rooms/\(roomID)/socket" }
    var queryItems: [URLQueryItem]? {
        [URLQueryItem(name: "history", value: "10")]
    }
    var headers: [String: String]? {
        ["Authorization": "Bearer TOKEN"]
    }
    var subprotocols: [String] { ["chat.v1"] }
    var maximumMessageSize: Int? { 1_048_576 }
    var inboundBufferingPolicy: WebSocketInboundBufferingPolicy {
        .init(maximumMessages: 64, maximumBytes: 8 * 1_024 * 1_024)
    }
}

let connection = try await client.connect(ChatSocket(roomID: "lobby"))

let lifecycleTask = Task {
    for await state in connection.states {
        print(state)
    }
}

try await connection.send(text: "hello")
let firstMessage = try await connection.receive()

for try await message in connection.messages {
    print(message)
    break
}

try await connection.ping()
try await connection.close(code: .normalClosure, reason: "Done")
```

Use either `receive()` or `messages`; only one public receive may be active on a
connection at a time. After the handshake, the SDK continuously keeps one
Foundation receive armed so peer closure is observable even while the
application is idle. Complete messages are retained FIFO until a consumer asks
for them. Messages accepted before closure remain drainable; a normal or
going-away close then ends `messages`, while abnormal closure is thrown. `close`
starts the closing handshake and returns without waiting for the peer to finish
it. Services can depend on `any WebSocketClientProtocol`, and can retain the
returned `any WebSocketConnectionProtocol` without depending on `APIClient`
directly.

`inboundBufferingPolicy` bounds that retained FIFO. Its default is 64 messages
and 8 MiB of aggregate text UTF-8 or binary payload bytes. Exceeding either
limit rejects the incoming message, cancels the connection, preserves the
already accepted prefix for draining, and then throws
`WebSocketError.inboundBufferOverflow` with counts that do not retain the
rejected payload. `maximumMessageSize` remains Foundation's per-message limit;
the buffering policy is an aggregate retained-payload limit. Because one
Foundation message may be in flight, it is not a strict peak-memory ceiling.

The `AnotherFuckingNetworkingSDKTesting` product mirrors those semantics.
`MockWebSocketClient` includes the policy in exact-stub matching and structured
request records. `MockWebSocketConnection` accepts a validating custom-policy
initializer, exposes buffered message and payload-byte counts, delivers
directly to a waiting receiver without retaining the payload, and preserves an
accepted prefix across normal closure, injected failure, or typed overflow.
`reset()` clears that buffered and terminal state while retaining the mock's
immutable policy.

`states` emits an immediate lifecycle snapshot, pushes later `.open`,
`.closing`, and `.closed` transitions, and finishes after closure. Each
subscriber has a newest-only buffer, so an idle or slow observer cannot grow
memory without bound. The SDK connection and `MockWebSocketConnection` both
push peer closure without requiring a `state` poll or another I/O operation.
Custom `WebSocketConnectionProtocol` conformers keep source compatibility via
a one-snapshot default and can override `states` when they have push events.

On iOS 17 or macOS 14 and newer, a main-actor Observation adapter can bridge
that sequence directly into UI state while the connection remains actor
isolated off the main actor:

```swift
@MainActor
func makeSocketModel(
    for connection: any WebSocketConnectionProtocol
) -> ObservableWebSocketState {
    ObservableWebSocketState(connection: connection)
}
```

Rejected upgrades throw `WebSocketError.handshakeFailed` with status and response-header metadata. URL, subprotocol, reserved-header, message-size, transport, and close failures remain distinct cases. `APIClient` installs a task-specific delegate to observe the upgrade and close lifecycle; authentication, redirects, cookies, metrics, and the intercepted lifecycle events still flow through the injected session's delegate. Do not install a competing task-specific delegate from `urlSession(_:didCreateTask:)` for these WebSocket tasks.

Cancellation is connection-scoped. Cancelling an active `connect`, `send`,
`receive`, or `ping` preserves `CancellationError` and cancels the underlying
socket task, closing that connection for every task that shares it. Breaking a
`messages` loop stops consumer demand, but the SDK receive pump remains active;
the bounded policy therefore still applies while that consumer is idle.
Cancelling an in-flight iteration closes the connection.

The SDK deliberately does not reconnect automatically or choose a heartbeat schedule. Reconnect backoff, session restoration, and ping intervals/timeouts are application policy; call `ping()` directly or build that policy around `WebSocketClientProtocol`.

## Empty responses

Declare `EmptyResponse` for successful endpoints that intentionally return no body, including `204` and `205` responses:

```swift
struct DeleteUserRequest: Request {
    typealias ReturnType = EmptyResponse

    let userID: Int
    var path: String { "users/\(userID)" }
    var method: HTTPMethod { .delete }
}

_ = try await client.send(DeleteUserRequest(userID: 42))
```

An empty body for any other response type throws `NetworkError.emptyResponse` instead of being reported as a JSON decoding problem.

## Pagination

`PaginatedRequest` preserves the base URL query, request filters, and custom URL construction while replacing existing pagination keys exactly once.

```swift
struct ListUsersRequest: PaginatedRequest {
    typealias ReturnType = User

    let page: Int
    let pageSize: Int
    let role: String

    var path: String { "users" }
    var queryItems: [URLQueryItem]? {
        [URLQueryItem(name: "role", value: role)]
    }
}

let response = try await client.sendPage(
    ListUsersRequest(page: 1, pageSize: 50, role: "admin")
)

if let nextPage = response.nextPage {
    let next = try await client.sendPage(
        ListUsersRequest(page: nextPage, pageSize: 50, role: "admin")
    )
    print(next.items)
}
```

Override `pageQueryName` and `pageSizeQueryName` for APIs that use alternate page-number names such as `page_number` and `per_page`. Only the query names change; the page number is not converted into an item offset. Cursor and offset pagination are intentionally outside this page-number abstraction and should be modeled as ordinary `Request` values.

## Error handling and cancellation

Cancellation is preserved as `CancellationError`. Handle it before `NetworkError`:

```swift
do {
    let user = try await client.send(GetUserRequest(userID: 42))
    print(user)
} catch is CancellationError {
    // The surrounding task was cancelled.
} catch let error as NetworkError {
    switch error {
    case .invalidURL:
        print("The base URL or endpoint path is invalid")
    case .invalidResponse:
        print("The response was not HTTP")
    case .encodingFailed(let underlying):
        print("Could not encode the request: \(underlying)")
    case .requestConfigurationFailed(let underlying):
        print("Could not configure the request: \(underlying)")
    case .transport(let urlError):
        print("Transport failed with \(urlError.code)")
    case .requestFailed(let statusCode, let data):
        print("HTTP \(statusCode), body bytes: \(data?.count ?? 0)")
    case .emptyResponse(let statusCode):
        print("HTTP \(statusCode) did not contain the expected body")
    case .decodingFailed(let underlying):
        print("Could not decode the response: \(underlying)")
    case .fileOperationFailed(let underlying):
        print("Could not read or store a transfer file: \(underlying)")
    case .unknown(let underlying):
        print("Unexpected failure: \(underlying)")
    }
}
```

HTTP error bodies are preserved as `Data?` for endpoint-specific decoding. Standard URL failures remain inspectable as `URLError` inside `.transport`.

## Activity streams and Observation

Inject `NetworkActivityMonitor` when an app needs privacy-safe request state.
Monitoring is opt-in, so clients without a monitor keep the direct request fast
path. Snapshots contain counts only—never URLs, headers, bodies, or errors—and
each subscriber uses a newest-only buffer so a slow UI cannot grow memory
without bound.

```swift
let monitor = NetworkActivityMonitor()
let client = APIClient(
    baseURL: URL(string: "https://api.example.com")!,
    activityMonitor: monitor
)

let activityTask = Task {
    for await snapshot in monitor.snapshots() {
        print(snapshot.totalActiveCount)
    }
}

_ = try await client.send(GetUserRequest(userID: 42))
activityTask.cancel()
```

The all-platform stream supports the package's iOS 15 and macOS 12 floor. On
iOS 17 or macOS 14 and newer, `ObservableNetworkActivity` provides a
main-actor `@Observable` presentation model with separate properties for HTTP
requests, uploads, downloads, WebSocket handshakes, and outcomes:

```swift
@MainActor
func makeActivityModel(
    for monitor: NetworkActivityMonitor
) -> ObservableNetworkActivity {
    ObservableNetworkActivity(monitor: monitor)
}
```

Only the small presentation adapter runs on the main actor. URL construction,
encoding, URLSession work, logging, and decoding remain outside it.

## Safe request logging

Logging is disabled unless a logger is passed to the client.

```swift
let logger = NetworkingLogger(
    configuration: .init(
        bodyPolicy: .redactedJSON(maximumBytes: 16_384),
        minimumLevel: .info
    )
)

let client = APIClient(
    baseURL: URL(string: "https://api.example.com")!,
    logger: logger
)
```

The logger redacts URL paths by default because identifiers and reset tokens often appear in path components. It also redacts common authorization, cookie, API-key, token, password, secret, and OAuth-code fields; recursively redacts configured JSON keys; omits invalid, binary, or oversized bodies; removes URL credentials and fragments; sorts output deterministically; and POSIX-quotes cURL arguments.

Body contents are omitted by default. Set `urlPathPolicy: .included` only when endpoint paths cannot contain sensitive values, and review custom redaction sets before enabling JSON body logging for a production API. Raising `minimumLevel` skips lower-level message construction entirely; for example, `.info` avoids building request cURL strings.

You can inject a `Sendable` sink for tests or another logging backend:

```swift
let logger = NetworkingLogger { level, sanitizedMessage in
    print("[\(level)] \(sanitizedMessage)")
}
```

Only sanitized messages reach the sink.

## Service injection

Depend on `any APIClientProtocol` when a service should accept either the real or mock client:

```swift
struct UserService: Sendable {
    let client: any APIClientProtocol

    func user(id: Int) async throws -> User {
        try await client.send(GetUserRequest(userID: id))
    }
}
```

Use `any APIClientResponseProtocol` instead when the service calls `sendResponse(_:)` or `sendPageResponse(_:)`. Both `APIClient` and `MockAPIClient` conform.

Services that upload or download can depend on `any APIClientTransferProtocol`.

## Testing support

Add the testing product only to test targets:

```swift
.testTarget(
    name: "YourAppTests",
    dependencies: [
        "YourApp",
        .product(
            name: "AnotherFuckingNetworkingSDKTesting",
            package: "AnotherFuckingNetworkingSDK"
        )
    ]
)
```

Register type-wide stubs and inspect calls through the actor with `await`:

```swift
import AnotherFuckingNetworkingSDK
import AnotherFuckingNetworkingSDKTesting

let mock = MockAPIClient()
let expected = User(id: 42, displayName: "Arthur")
await mock.stub(GetUserRequest.self, with: expected)

let service = UserService(client: mock)
let user = try await service.user(id: 42)
let calls = await mock.recordedRequests
```

Exact request stubs take precedence over type-wide defaults:

```swift
await mock.stub(
    GetUserRequest.self,
    with: User(id: 0, displayName: "Default")
)
try await mock.stub(
    GetUserRequest(userID: 42),
    with: User(id: 42, displayName: "Exact")
)
```

Exact-instance registration uses `try await` because the mock constructs the request's final URL and encoded body at registration time. Pass the production base URL, global headers, and encoder factory to `MockAPIClient` when those values affect matching. Recorded calls include the final URL, headers, and in-memory body.

Paginated responses use the dedicated, compile-time-safe API:

```swift
let page = PaginatedResponse(
    items: [expected],
    currentPage: 1,
    totalPages: 1
)
await mock.stubPage(ListUsersRequest.self, with: page)
```

Metadata-aware stubs use `stubResponse` or `stubPageResponse`:

```swift
await mock.stubResponse(
    GetUserRequest.self,
    with: HTTPResponse(
        value: expected,
        data: Data(),
        metadata: HTTPResponseMetadata(
            statusCode: 200,
            headers: ["ETag": "user-42"]
        )
    )
)
```

Ordinary value stubs also satisfy response sends with deterministic HTTP `200` metadata and the mock's fully constructed URL. Exact matching and recordings include final URL, method, headers, and body changes made by `customize(_:)`.

Unregistered ordinary and paginated calls throw `MockAPIClientError.missingStub`; the mock never manufactures an empty success. Registered failures, injected delays, task cancellation, reset behavior, and concurrent request recording are deterministic.

Transfer services can inject the same mock through `APIClientTransferProtocol`:

```swift
let transferMock = MockAPIClient()
let transferClient: any APIClientTransferProtocol = transferMock
let sourceURL = URL(fileURLWithPath: "/fixtures/avatar.jpg")

await transferMock.stubUpload(
    UploadAvatarRequest.self,
    with: HTTPResponse(
        value: User(id: 42, displayName: "Arthur"),
        metadata: HTTPResponseMetadata(statusCode: 201)
    )
)
await transferMock.stubDownload(
    ExportRequest.self,
    using: { transfer in
        DownloadResponse(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("mock-download-\(transfer.sequenceID)"),
            metadata: HTTPResponseMetadata(statusCode: 200)
        )
    }
)

let upload = try await transferClient.upload(
    UploadAvatarRequest(userID: 42),
    from: .file(sourceURL)
)
let firstDownload = try await transferClient.download(
    ExportRequest(exportID: "latest")
)
let secondDownload = try await transferClient.download(
    ExportRequest(exportID: "latest")
)
let transfers = await transferMock.recordedTransfers
```

Mock transfers perform no filesystem I/O. A file upload source does not need to exist, download destinations are matched and recorded without being created or replaced, and a `DownloadResponse` returns exactly the URL supplied by its stub. Consequently, the mock does not reproduce production failures for missing or unreadable sources and existing destinations; cover those policies with `APIClient` transfer tests. Use a download factory, as above, when repeated temporary downloads need distinct URLs. `recordedTransfers` preserves invocation order and includes the final URL, headers, request body, upload source, or download destination. Transfer sequence IDs remain monotonic for the mock's lifetime, including across `clearRecordedTransfers()` and `reset()`, so in-flight factories cannot reuse an identifier. Clearing records leaves stubs intact; `reset()` clears all stubs and recordings.

WebSocket services can use the same protocol-based pattern with
`MockWebSocketClient` and `MockWebSocketConnection`:

```swift
let socket = MockWebSocketConnection(
    url: URL(string: "wss://api.example.com/rooms/lobby/socket")!,
    negotiatedSubprotocol: "chat.v1",
    incoming: [
        .success(.text("welcome")),
        .success(.binary(Data([0x01, 0x02])))
    ]
)
let socketClient = MockWebSocketClient(
    baseURL: URL(string: "https://api.example.com")
)
await socketClient.stub(ChatSocket.self, with: socket)

let connection = try await socketClient.connect(
    ChatSocket(roomID: "lobby")
)
try await connection.send(text: "hello")

#expect(try await connection.receive() == .text("welcome"))
#expect(await socket.sentMessages == [.text("hello")])
```

The client supports type-wide and exact request stubs, errors, and async
connection factories. Exact matching uses the fully constructed handshake,
including the final URL and headers, ordered subprotocols, and maximum message
size. Factories are recommended when every connect should receive an independent
connection.

The connection mock consumes incoming messages, send results, and ping results
in FIFO order. It mirrors production's single-active-receive rule and treats an
operation failure or cancellation as connection-scoped. A pending receiver can
be completed with `enqueueIncoming`, `finish`, or `fail`. Its unified
`recordedOperations` sequence preserves the order of sends, receives, pings, and
closes without wall-clock sleeps or live networking. Request and operation
sequence IDs remain monotonic for each mock's lifetime, including across clear
and reset calls. Its `states` sequence mirrors production lifecycle events and
starts a fresh open sequence after `reset()`.

## 1.x to 2.x migration

Version 2 is a deliberate major-version modernization:

- Adopt Swift 6.
- Add `Sendable` to request and decoded response types.
- Import `AnotherFuckingNetworkingSDKTesting` in tests and change mock setup or inspection to use `await`.
- Replace hand-written socket doubles with `MockWebSocketClient` and `MockWebSocketConnection` where deterministic queue behavior is sufficient.
- Add `try` when registering exact request-instance stubs; URL or body construction can now fail explicitly.
- Replace mock inheritance assumptions with `any APIClientProtocol` injection.
- Replace `APIClient` subclasses with protocol-based wrappers or injected `APIClientProtocol` values; `APIClient` is now `final`.
- Use `stubPage` for paginated responses.
- Replace direct `mockDelay` mutation with the `MockAPIClient(delay:sleeper:)` initializer or `await mock.setDelay(_:)`.
- Expect missing page stubs to throw instead of returning an empty page.
- Handle `.transport`, `.encodingFailed`, `.invalidResponse`, and `.emptyResponse` in `NetworkError` switches.
- Handle `.requestConfigurationFailed` when request customization is used.
- Handle `.fileOperationFailed` when using file-backed transfers.
- Handle `CancellationError` separately.
- Pass `NetworkingLogger` explicitly when diagnostics are wanted.
- Move app-specific sample models out of the SDK namespace.
- Replace the removed general-purpose dictionary merge and nonce helpers with app-owned utilities.

The familiar `send`, `sendPage`, `ReturnType`, `APIClient.shared`, `baseURL`, `globalHeaders`, and pre-encoded `body` APIs remain available. `ReturnType` no longer needs to be `Decodable` when a request supplies custom decoding. Ordinary `Request` values now inherit their URL construction from `HTTPRequest`, which also powers `DownloadRequest`.

## Development

Run the test and strict concurrency gates:

```sh
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test -c release -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

HTTP tests use isolated `URLProtocol` handlers rather than external network
calls and are safe to run in parallel. A serialized, dependency-free server on
an ephemeral `127.0.0.1` port verifies Foundation's real WebSocket upgrade,
framing, ping, close, rejection, metrics, and delegate paths. CI also performs
unsigned iOS 15 release builds for both public products.

## License

MIT. See [LICENSE](LICENSE).
