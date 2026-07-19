---
name: afn-networking-sdk
description: Implement, review, test, and document AnotherFuckingNetworkingSDK features on Apple platforms. Use when changing Swift 6 networking code, HTTP requests, streaming, authentication, uploads/downloads, WebSockets, Observation, mocks, concurrency boundaries, or release gates in this repository.
---

# AFN Networking SDK

## Overview

Use this skill to make repository changes that preserve the SDK's concurrency,
cancellation, replay, privacy, and lifecycle invariants. Inspect the current
source and tests before relying on any example below.

## Workflow

1. **Inventory the surface.** Read `Package.swift`, the relevant source file,
   its tests, and the matching guide in `docs/`. Confirm the minimum platform
   and whether the change is public API, testing API, or internal behavior.
2. **Choose the smallest policy boundary.** Extend a protocol or add an
   opt-in adapter instead of adding global mutable state or a second transport
   stack. Keep advanced concerns in separate types/products when possible.
3. **Design for Swift 6.** Public values crossing tasks are `Sendable`; mutable
   shared state belongs in an actor or `CriticalState`; synchronous request
   construction must remain nonisolated and cheap.
4. **Preserve lifecycle semantics.** Check cancellation before work, across
   every suspension, and at irreversible commits. A returned stream or file
   owns its underlying resource until EOF, failure, cancellation, or explicit
   disposal.
5. **Add deterministic tests.** Prefer `URLProtocol` fixtures, actor mocks,
   injected clocks/sleepers, and bounded queues. Test both success and every
   cancellation/error boundary.
6. **Document and commit.** Update the relevant guide and README example, run
   strict Debug and Release validation, then commit one coherent PR-sized
   slice. Do not claim a GitHub PR exists until it is actually pushed and
   created.

## Capability map

- Typed JSON/raw requests: `Request`, `RawDataRequest`, `HTTPResponse`.
- Streaming: `APIClientStreamingProtocol`, `HTTPByteStream`, bounded
  `ServerSentEventStream`, and typed `JSONLinesStream`; status and retry
  decisions finish before bytes are exposed, while protocol framing stays in
  cancellation-owned adapters.
- Auth: `HTTPAuthenticator`, `SingleFlightTokenProvider`,
  `AuthenticatedAPIClient`; 401 replay is idempotency-aware.
- Transfers: `APIClientTransferProtocol`, `UploadBody`,
  `StreamingMultipartFormData`, `DownloadDestination`, durable file ownership;
  known file/multipart lengths are exposed through `Content-Length` before
  `customize(_:)` for body-free signing.
- Background transfer state: `TransferJob`, `TransferJobStore`,
  `TransferJobCoordinator`, `BackgroundURLSessionAdapter`, and
  `BackgroundTransferLifecycleCoordinator`; keep request resolution,
  authentication, and destination commits in application policy. Reconcile
  task IDs with `BackgroundTransferEventRouter`, then use the lifecycle actor
  to start restored jobs, checkpoint progress, commit downloads, and record
  failures. Completion callbacks carrying bounded resume data become paused
  jobs; non-resumable callbacks become failures. Use
  `reconcile(adapter:)` after relaunch to validate identity/direction and
  inspect orphaned or mismatched task IDs, then re-enqueue
  `jobsWithoutTasks` before handling events. Use the adapter's typed
  `pauseDownload`, `resume`, and `cancel` controls instead of reaching into
  raw URLSession tasks; persist returned bounded resume data through the
  coordinator. The `download` and `downloadValidated` APIs accept
  `startImmediately: false` so an app can bind the Foundation task identifier
  before resuming and avoid a callback/routing race. The repository's
  `Examples/BackgroundTransferHost` project is the reference signed-host
  fixture for device and process-relaunch validation. The
  Foundation background adapter is iOS/macOS-only; pair the durable
  coordinator with platform-owned transports on tvOS, watchOS, and visionOS.
- Progress: `APIClientTransferProgressProtocol`, `TransferProgress`; callbacks
  are opt-in and must remain lightweight.
- WebSocket recovery: WebSocketRecoveryAdapter provides bounded in-memory or
  JSON cursor/session state for WebSocketReliabilityClient; use
  JSONWebSocketRecoveryAdapter for `Codable & Sendable` checkpoints when a
  typed seam is useful. Keep replay and authentication semantics
  application-owned, and persist only bounded, redacted/encrypted data.
- WebSockets: `WebSocketRequest`, `WebSocketConnectionProtocol`, bounded FIFO
  buffering, lifecycle state, Observation adapters, opt-in
  `WebSocketReliabilityClient` reconnect/heartbeat policies, and
  `WebSocketMessageCodec`/`JSONWebSocketMessageCodec` typed message helpers.
- Diagnostics: `NetworkActivityMonitor`, `NetworkingLogger`; never log tokens,
  cookies, bodies, or sensitive URLs by default.
- Connectivity: `NetworkPathMonitor` provides newest-only path snapshots for
  UI or policy selection; `ObservableNetworkPath` is the iOS 17+/macOS 14+
  Observation adapter; never add a reachability preflight that blocks a
  request.
- Telemetry: `NetworkTelemetry`, privacy-safe operation/attempt events, and
  `NetworkTelemetryExporter`, `NetworkTaskMetricsSnapshot`; keep exporters
  lightweight and vendor-neutral. Transfer delegates emit separate
  `taskMetrics` events through the snapshot initializer without retaining URL
  or payload data, even when progress callbacks are disabled. WebSocket task
  delegates use the same path after the upgrade handshake.
- Request coalescing: `RequestCoalescingAPIClient`; caller-keyed single-flight
  sharing that never retains completed responses.
- Request concurrency: `RequestConcurrencyLimiter` and
  `ConcurrencyLimitedAPIClient`; actor-isolated FIFO permits with cancellation
  aware waiters and a bounded waiting queue. The response decorator covers complete response operations,
  including retries and decoding, but deliberately does not pretend to bound
  stream/file lifetimes.
- Response caching: `CachedAPIClient`, `ConditionalCachedAPIClient`, and
  `ResponseCachePolicy`; bounded caller-keyed TTL/LRU storage, optional
  validator revalidation, and explicit invalidation.
- Circuit breaking: `CircuitBreaker` and `CircuitBreakingAPIClient`; use
  caller-owned keys, classify only failures that should suppress an endpoint,
  preserve cancellation, and inject a clock for deterministic cooldown tests.
- Testing: `AnotherFuckingNetworkingSDKTesting` actor mocks and URL protocol
  fixtures; finite stream stubs, progress callbacks, and wrapper-aware
  type-wide matching mock one logical call rather than URLSession retry
  attempts.

## Non-negotiable invariants

- Snapshot mutable client configuration once before transport suspension.
- Default HTTP retries are off. Opt-in retries require bounded, replay-safe
  policy; never retry after a successful stream has exposed a byte.
- Authentication refresh retries only idempotent methods by default. A
  mutation must declare `.explicitlyReplayable`.
- Status acceptance and body decoding are independent decisions.
- Never buffer unbounded response, multipart, WebSocket, or error data. The
  client defaults to a 32 MiB buffered/streamed response limit; preserve that
  policy through request wrappers and use explicit per-request overrides only
  when an endpoint has a justified bound (or intentionally opts out with
  `nil`).
- Preserve `CancellationError`; do not turn cancellation into a generic
  transport or retry failure.
- File cleanup is ownership-aware and must run even when the awaiting task is
  cancelled.
- Observation/activity streams are newest-only and privacy-safe.
- Background callbacks are actor-serialized; never mark a download succeeded
  before the application-owned temporary-file commit returns.

## Change-specific guidance

### HTTP and streaming

Build URLs and bodies through `HTTPRequest`; let Foundation's `URLSession`
provide HTTP/2, HTTP/3, cookies, ATS, redirects, and auth challenges. Use
`HTTPByteStream` for large or long-lived bodies. Use `ServerSentEventStream`
for bounded SSE framing and `JSONLinesStream`/`streamJSONLines` for typed
NDJSON. Keep product-specific framing in an adapter rather than the transport
core. See
[`docs/architecture.md`](../../docs/architecture.md) and
[`docs/authentication-and-retries.md`](../../docs/authentication-and-retries.md).

### Transfers and files

Use `.data` only for bounded in-memory uploads; use `.file` for large raw
uploads and `.multipart(StreamingMultipartFormData)` for large mixed forms.
The multipart writer uses bounded chunks and a temporary owned upload file.
Downloads must validate destinations before transport and move the temporary
Foundation file into caller-visible storage exactly once. Background sessions,
resume data, and relaunch recovery belong in a lifecycle-bound module. Use
`BackgroundURLSessionAdapter` for Foundation delegate events and keep
`TransferJobCoordinator` as the single durable state writer; pass `jobID` when
creating background tasks and reconcile `transferTasks()` after relaunch so
task identifiers route back to durable jobs. Use `BackgroundTransferEventRouter`
for actor-isolated collision checks and `BackgroundTransferLifecycleCoordinator`
to apply callbacks. Supply an explicit destination committer and do not mark
success until it completes. Do not pretend a foreground convenience task is
durable. Validate persisted resume data with
`BackgroundTransferResumeDataValidator`; use its default bounded mode for
forward compatibility and `.propertyList` only as an opt-in integrity check.
When binding a just-created task, create it with `startImmediately: false`,
bind its returned task ID, then call `resume(taskIdentifier:)`.

### WebSockets and Observation

Keep one receive owner. Preserve FIFO order with a bounded buffer and fail
closed on overflow. Do not add automatic reconnect or heartbeat behavior to
the base connection; use `WebSocketReliabilityClient` when bounded retry and
session restoration are explicitly desired. Prefer `restorerWithContext` when
a server cursor or session token needs the reconnect attempt and prior
subprotocol. Use WebSocketRecoveryAdapter when that opaque state must survive
process termination; persist only bounded, redacted/encrypted data and never
assume the SDK can decode a product protocol. Use `WebSocketMessageCodec` for
typed payloads; its decoded sequence must delegate to the existing `messages`
sequence rather than starting another receive pump. See
[`docs/websockets-and-transfers.md`](../../docs/websockets-and-transfers.md).

### Request coalescing

Wrap a response-capable client in `RequestCoalescingAPIClient` for duplicate
concurrent reads. Make the key include request type, URL inputs, auth scope,
and feature flags; return `nil` when an operation must always execute. This is
single-flight only, not a response cache.

Use `RequestConcurrencyLimiter` when the service needs a hard bound on
complete response operations. Compose `ConcurrencyLimitedAPIClient` at the
boundary whose retries and decoding should count against the limit. Do not
wrap a streaming or transfer method with a short-lived permit; the returned
resource outlives the call and requires a lease that remains owned until EOF or
file commit.

### Response caching

Use `CachedAPIClient` or `ConditionalCachedAPIClient` only for explicitly
cacheable successful reads. Include request type, URL inputs, auth scope,
locale, and feature flags in the key; invalidate after successful writes.
Conditional caching retains only bounded `ETag`/`Last-Modified` values and
refreshes stale entries on `304`, while pagination methods remain forwarded
unless you call `sendResponse(_:)` explicitly.

### Tests and release gates

Run the repository's strict suite with a writable module-cache location when
the sandbox blocks the default cache:

```sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/afn-clang-module-cache \
    SWIFT_MODULECACHE_PATH=/private/tmp/afn-swift-module-cache \
    swift test -Xswiftc -strict-concurrency=complete \
      -Xswiftc -warnings-as-errors
```

Also run Release/library-evolution builds for public API changes. Add tests
for cancellation, retries, metadata, redaction, actor isolation, and the
oldest supported platform when behavior crosses a platform boundary. The
package declares iOS 15, macOS 12, tvOS 15, watchOS 8, and visionOS 1 targets;
CI evaluates additional product builds when those SDKs are installed and
always builds iOS, macOS, and Mac Catalyst.
For background/relaunch work, also build
`Examples/BackgroundTransferHost/BackgroundTransferHost.xcodeproj` for a
generic iOS destination; sign it with the integrating app's team before
attempting physical-device execution.

## Repository references

- [`README.md`](../../README.md) — public usage and migration examples.
- [`docs/`](../../docs/README.md) — user guides, architecture, security, and
  release documentation.
- [`Package.swift`](../../Package.swift) — products and deployment targets.
- [`Sources/AnotherFuckingNetworkingSDK/`](../../Sources/AnotherFuckingNetworkingSDK/) — production implementation.
- [`Tests/AnotherFuckingNetworkingSDKTests/`](../../Tests/AnotherFuckingNetworkingSDKTests/) — behavioral contract.

## Installing the repository skill

This workspace stores the skill at `skills/afn-networking-sdk` because the
workspace-managed `.agents` directory is read-only. To install it for a local
Codex profile, copy the directory into that profile's skills directory or use
the repository path with the skill installer. Keep `SKILL.md` and
`agents/openai.yaml` together.
