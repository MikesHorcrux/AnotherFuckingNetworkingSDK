# AnotherFuckingNetworkingSDK

A small, zero-dependency networking package for Swift 6. It provides typed requests, async URLSession transport, page-number pagination, explicit empty responses, safe opt-in diagnostics, and a separate actor-based testing library.

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
    case .transport(let urlError):
        print("Transport failed with \(urlError.code)")
    case .requestFailed(let statusCode, let data):
        print("HTTP \(statusCode), body bytes: \(data?.count ?? 0)")
    case .emptyResponse(let statusCode):
        print("HTTP \(statusCode) did not contain the expected body")
    case .decodingFailed(let underlying):
        print("Could not decode the response: \(underlying)")
    case .unknown(let underlying):
        print("Unexpected failure: \(underlying)")
    }
}
```

HTTP error bodies are preserved as `Data?` for endpoint-specific decoding. Standard URL failures remain inspectable as `URLError` inside `.transport`.

## Safe request logging

Logging is disabled unless a logger is passed to the client.

```swift
let logger = NetworkingLogger(
    configuration: .init(
        bodyPolicy: .redactedJSON(maximumBytes: 16_384)
    )
)

let client = APIClient(
    baseURL: URL(string: "https://api.example.com")!,
    logger: logger
)
```

The logger redacts URL paths by default because identifiers and reset tokens often appear in path components. It also redacts common authorization, cookie, API-key, token, password, secret, and OAuth-code fields; recursively redacts configured JSON keys; omits invalid, binary, or oversized bodies; removes URL credentials and fragments; sorts output deterministically; and POSIX-quotes cURL arguments.

Body contents are omitted by default. Set `urlPathPolicy: .included` only when endpoint paths cannot contain sensitive values, and review custom redaction sets before enabling JSON body logging for a production API.

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

Exact-instance registration uses `try await` because the mock constructs the request's final URL and encoded body at registration time. Pass the production base URL and encoder factory to `MockAPIClient` when those values affect matching. Recorded calls include that final URL and body.

Paginated responses use the dedicated, compile-time-safe API:

```swift
let page = PaginatedResponse(
    items: [expected],
    currentPage: 1,
    totalPages: 1
)
await mock.stubPage(ListUsersRequest.self, with: page)
```

Unregistered ordinary and paginated calls throw `MockAPIClientError.missingStub`; the mock never manufactures an empty success. Registered failures, injected delays, task cancellation, reset behavior, and concurrent request recording are deterministic.

## 1.x to 2.x migration

Version 2 is a deliberate major-version modernization:

- Adopt Swift 6.
- Add `Sendable` to request and decoded response types.
- Import `AnotherFuckingNetworkingSDKTesting` in tests and change mock setup or inspection to use `await`.
- Add `try` when registering exact request-instance stubs; URL or body construction can now fail explicitly.
- Replace mock inheritance assumptions with `any APIClientProtocol` injection.
- Replace `APIClient` subclasses with protocol-based wrappers or injected `APIClientProtocol` values; `APIClient` is now `final`.
- Use `stubPage` for paginated responses.
- Replace direct `mockDelay` mutation with the `MockAPIClient(delay:sleeper:)` initializer or `await mock.setDelay(_:)`.
- Expect missing page stubs to throw instead of returning an empty page.
- Handle `.transport`, `.encodingFailed`, `.invalidResponse`, and `.emptyResponse` in `NetworkError` switches.
- Handle `CancellationError` separately.
- Pass `NetworkingLogger` explicitly when diagnostics are wanted.
- Move app-specific sample models out of the SDK namespace.
- Replace the removed general-purpose dictionary merge and nonce helpers with app-owned utilities.

The familiar `send`, `sendPage`, `ReturnType`, `APIClient.shared`, `baseURL`, `globalHeaders`, and pre-encoded `body` APIs remain available.

## Development

Run the test and strict concurrency gates:

```sh
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test -c release -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

The suite uses isolated `URLProtocol` handlers rather than live network calls and is safe to run in parallel. CI also performs unsigned iOS 15 release builds for both public products.

## License

MIT. See [LICENSE](LICENSE).
