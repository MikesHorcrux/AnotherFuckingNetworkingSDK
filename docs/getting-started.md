# Getting started

## Install

Add the package by URL in Xcode or to `Package.swift`:

```swift
dependencies: [
    .package(
        url: "https://github.com/MikesHorcrux/AnotherFuckingNetworkingSDK.git",
        from: "2.0.0"
    )
]
```

Import `AnotherFuckingNetworkingSDK` in production targets. Import
`AnotherFuckingNetworkingSDKTesting` only in test targets.

## Configure a client

```swift
let client = APIClient(
    baseURL: URL(string: "https://api.example.com")!,
    globalHeaders: ["Accept": "application/json"]
)
```

`APIClient.shared` is available for small applications, but dependency
injection is preferred for services and tests. Configuration reads and writes
are synchronized. Call `updateConfiguration` when changing multiple fields so
each new operation sees one complete snapshot:

```swift
client.updateConfiguration { configuration in
    configuration.baseURL = URL(string: "https://staging.example.com")!
    configuration.globalHeaders["X-Environment"] = "staging"
}
```

An in-flight operation retains its original base URL, headers, and codec
factories. A later configuration update does not create a mixed request.

### Bound response memory

Buffered request APIs use a 32 MiB response-body limit by default. Configure a
different positive limit per client, or set it to `nil` only when an
application explicitly accepts unbounded buffering:

```swift
let client = APIClient(
    baseURL: URL(string: "https://api.example.com")!,
    maximumResponseBodyBytes: 8 * 1_024 * 1_024
)
```

An endpoint can override the client policy by implementing
`maximumResponseBodyBytes` on its `HTTPRequest`. Oversized buffered responses
throw `NetworkError.responseBodyTooLarge` before decoding. Streaming requests
apply the same limit as bytes are consumed and throw
`HTTPByteStreamError.responseBodyTooLarge`; the URLSession task is cancelled
as soon as the first excess byte is observed.

### Apply a final request policy

Use `requestCustomizer` for concerns that must see the fully assembled
`URLRequest`, including the resolved URL, method, encoded body, and content
length. The hook runs after the endpoint's own `customize(_:)` implementation
and applies consistently to ordinary requests, pagination, streams, uploads,
downloads, and WebSocket upgrades. WebSocket upgrades still run strict
Foundation-handshake validation after the hook:

```swift
let client = APIClient(
    baseURL: URL(string: "https://api.example.com")!,
    requestCustomizer: { request in
        request.setValue(
            UUID().uuidString,
            forHTTPHeaderField: "X-Request-ID"
        )
        request.setValue(
            "AnotherFuckingNetworkingSDK/2",
            forHTTPHeaderField: "User-Agent"
        )
    }
)
```

This is also the right seam for signing the final URL and body. If the hook
throws, no transport is started and the error is reported as
`NetworkError.requestConfigurationFailed`. Use `updateConfiguration` to
replace the hook atomically with the rest of a client configuration.

## Define a typed request

```swift
struct User: Codable, Sendable {
    let id: Int
    let displayName: String
}

struct GetUser: Request {
    typealias ReturnType = User

    let id: Int
    var path: String { "users/\(id)" }
}

let user = try await client.send(GetUser(id: 42))
```

Requests are values. They declare the path, method, query, headers, body,
status policy, retry policy, and decoding behavior. `Request` gets JSON
decoding automatically when `ReturnType: Decodable`.

For endpoints that return bytes without JSON decoding, conform to
`RawDataRequest`. For intentionally bodyless success, use `EmptyResponse` or
set `allowsEmptyResponseBody` explicitly.

## Inspect metadata

```swift
let response = try await client.sendResponse(GetUser(id: 42))
print(response.value)
print(response.statusCode)
print(response.value(forHTTPHeaderField: "ETag") ?? "missing")
```

Headers are normalized to lowercase and looked up case-insensitively. A
non-success response throws `NetworkError.requestFailed(HTTPFailure)` with
status, URL, headers, and bounded body data.

## Stream a large response

```swift
let stream = try await client.stream(GetUser(id: 42))
var bytes = Data()
for try await byte in stream {
    bytes.append(byte)
}
```

The SDK validates status and finishes replay-safe retries before returning the
stream. Once a byte is exposed, the operation is single-pass and cannot be
replayed. Prefer a file download API when the final result is a durable file;
prefer a stream for SSE, NDJSON, incremental parsing, or bounded consumers.

## Upload and download

```swift
let uploadResponse = try await client.upload(
    CreateUser(name: "Trillian"),
    from: .data(payload)
)

let download = try await client.download(
    ExportRequest(exportID: "latest"),
    to: .temporary
)
defer { try? FileManager.default.removeItem(at: download.fileURL) }
```

Use `.file` uploads for large bodies. Download destinations are validated
before transport. The caller owns a returned temporary file and must remove it
when finished.

## Inject services

Depend on the narrowest protocol your service needs:

```swift
struct UserService {
    let client: any APIClientResponseProtocol

    func user(id: Int) async throws -> User {
        try await client.sendResponse(GetUser(id: id)).value
    }
}
```

Use `MockAPIClient` or a URL protocol fixture in tests. Keep retries and auth
as policy behavior in the client boundary rather than duplicating them in
every service.

## Observe connectivity without blocking requests

NetworkPathMonitor is optional and newest-only. It exposes privacy-safe
status, interface, cost, and constraint snapshots for UI, telemetry, or policy
selection; it never gates a request or replaces URLSession's
waitsForConnectivity behavior:

    let pathMonitor = NetworkPathMonitor()
    pathMonitor.start()

    for await snapshot in pathMonitor.snapshots {
        print(snapshot.status, snapshot.isExpensive)
    }

On iOS 17, macOS 14, and newer Observation-capable deployments, bind the same
monitor to `ObservableNetworkPath` for SwiftUI or other main-actor views. The
adapter mirrors only immutable snapshots; it does not move path monitoring or
request execution onto the main actor:

    @MainActor
    let connectivity = ObservableNetworkPath(monitor: pathMonitor)
    connectivity.start()

## Handle cancellation

`CancellationError` is preserved. Do not catch it as a generic transport
failure. Wrap only the work that must finish after cancellation (for example,
moving a completed download into its final destination) in an explicit commit
boundary; see [Concurrency and lifecycle](concurrency-and-lifecycle.md).
