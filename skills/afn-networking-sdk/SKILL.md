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
- Streaming: `APIClientStreamingProtocol`, `HTTPByteStream`; status and retry
  decisions finish before bytes are exposed.
- Auth: `HTTPAuthenticator`, `SingleFlightTokenProvider`,
  `AuthenticatedAPIClient`; 401 replay is idempotency-aware.
- Transfers: `APIClientTransferProtocol`, `UploadBody`,
  `DownloadDestination`, durable file ownership.
- Background transfer state: `TransferJob`, `TransferJobStore`, and
  `TransferJobCoordinator`; keep URLSession background delegates and request
  resolution in the application-owned adapter.
- Progress: `APIClientTransferProgressProtocol`, `TransferProgress`; callbacks
  are opt-in and must remain lightweight.
- WebSockets: `WebSocketRequest`, `WebSocketConnectionProtocol`, bounded FIFO
  buffering, lifecycle state, Observation adapters, and opt-in
  `WebSocketReliabilityClient` reconnect/heartbeat policies.
- Diagnostics: `NetworkActivityMonitor`, `NetworkingLogger`; never log tokens,
  cookies, bodies, or sensitive URLs by default.
- Telemetry: `NetworkTelemetry`, privacy-safe operation/attempt events, and
  `NetworkTelemetryExporter`; keep exporters lightweight and vendor-neutral.
- Request coalescing: `RequestCoalescingAPIClient`; caller-keyed single-flight
  sharing that never retains completed responses.
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
- Never buffer unbounded response, multipart, WebSocket, or error data.
- Preserve `CancellationError`; do not turn cancellation into a generic
  transport or retry failure.
- File cleanup is ownership-aware and must run even when the awaiting task is
  cancelled.
- Observation/activity streams are newest-only and privacy-safe.

## Change-specific guidance

### HTTP and streaming

Build URLs and bodies through `HTTPRequest`; let Foundation's `URLSession`
provide HTTP/2, HTTP/3, cookies, ATS, redirects, and auth challenges. Use
`HTTPByteStream` for large or long-lived bodies. Put SSE/NDJSON framing in an
adapter rather than the transport core. See
[`docs/architecture.md`](../../docs/architecture.md) and
[`docs/authentication-and-retries.md`](../../docs/authentication-and-retries.md).

### Transfers and files

Use `.data` only for bounded in-memory uploads; use `.file` for large uploads.
Downloads must validate destinations before transport and move the temporary
Foundation file into caller-visible storage exactly once. Background sessions,
resume data, and relaunch recovery belong in a lifecycle-bound module; do not
pretend a foreground convenience task is durable.

### WebSockets and Observation

Keep one receive owner. Preserve FIFO order with a bounded buffer and fail
closed on overflow. Do not add automatic reconnect or heartbeat behavior to
the base connection; use `WebSocketReliabilityClient` when bounded retry and
session restoration are explicitly desired. See
[`docs/websockets-and-transfers.md`](../../docs/websockets-and-transfers.md).

### Request coalescing

Wrap a response-capable client in `RequestCoalescingAPIClient` for duplicate
concurrent reads. Make the key include request type, URL inputs, auth scope,
and feature flags; return `nil` when an operation must always execute. This is
single-flight only, not a response cache.

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
oldest supported platform when behavior crosses a platform boundary.

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
