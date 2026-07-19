# Capability roadmap

This page separates shipped behavior from the work required to make the SDK a
complete networking platform. It is intentionally honest: a documented
roadmap item is not a shipped feature.

## Shipped foundation

- Swift 6 strict concurrency and synchronized client configuration.
- Typed requests, metadata, raw payloads, status policies, pagination, and
  replay-safe opt-in HTTP retries.
- Single-pass HTTP byte streams with bounded failures and lifecycle activity.
- Authenticated wrapper with single-flight token loading and safe 401 replay.
- Memory/file uploads, durable foreground downloads, multipart validation.
- Opt-in upload/download progress events with bounded byte counts and phases.
- Durable `TransferJob` records, JSON persistence, and cancellation-safe
  orchestration seams for app-owned background sessions.
- `BackgroundURLSessionAdapter` for Foundation background delegate events,
  progress, resume-data extraction, relaunch completion callbacks, and
  relaunch-safe task descriptors bound to durable job IDs.
- Actor-isolated `BackgroundTransferEventRouter` for collision-safe task-to-job
  reconciliation and typed post-relaunch event routing.
- Actor-isolated coordinator checkpoint, pause, failure, and terminal-success
  primitives for app-owned background callbacks.
- Actor-isolated `BackgroundTransferLifecycleCoordinator` that applies routed
  Foundation callbacks, commits temporary downloads through an explicit file
  policy, preserves idempotent terminal transitions, and pauses resumable
  completions with bounded resume data.
- Typed post-relaunch reconciliation reports that validate task identity and
  transfer direction before rebinding live Foundation tasks, including
  missing durable jobs that need explicit re-enqueue.
- `StreamingMultipartFormData` for bounded file-backed multipart uploads.
- Known upload lengths are available to request customization before
  file-backed signing and replay, without materializing the body.
- Opt-in operation and attempt telemetry with privacy-safe exporter events.
- Transfer delegate task-metrics telemetry with privacy-safe snapshots.
- WebSocket task-metrics telemetry wired through the injected URLSession
  delegate path.
- Bounded WebSocket receive pump, lifecycle state, Observation adapters, and
  loopback fixtures.
- Opt-in WebSocket reconnect, bounded backoff, heartbeat, and contextual
  session-restorer policies.
- Bounded, actor-isolated WebSocket recovery state stores and a contextual
  restorer adapter for application-defined cursors or session tokens.
- Optional typed JSON WebSocket recovery codec and adapter with deterministic
  encoding and bounded decode failures.
- Redacted logging, privacy-safe activity snapshots, and actor-based mocks.
- Validator-aware conditional caching with bounded `ETag`/
  `Last-Modified` revalidation.
- Optional NetworkPathMonitor snapshots for connectivity-aware UI and policy;
  transport requests remain non-blocking.

## Next production modules

1. **Platform background/resumable integration** — device/relaunch coverage,
   resume-data validation, and coordinator routing for the shipped
   `BackgroundURLSessionAdapter` on each supported Apple platform. The SDK now
   exposes stable task descriptors, an actor-isolated event router, a
   lifecycle coordinator with an explicit destination commit policy, and a
   typed relaunch reconciliation report; device coverage and platform
   terminal behavior remain.
2. **Platform task-metrics integration** — oldest-target and device coverage
   remain for the shipped HTTP, transfer, and WebSocket delegate integrations.
3. **Streaming multipart integration** — broader upload retry, signing, and
   oldest-target coverage for the shipped file-backed encoder.
4. **WebSocket platform hardening** — server-specific wire framing and
   oldest-target/device integration coverage. The reliability wrapper now
   supplies bounded reconnect context and an app-owned recovery-state store;
   protocol-specific wire framing and device integration remain app-owned;
   the optional JSON codec covers only transport-neutral `Codable` checkpoints.
5. **Platform matrix** — package declarations and availability guards now cover
   iOS, macOS, tvOS, watchOS, and visionOS, with Mac Catalyst builds in CI.
   CI builds the additional platforms whenever the runner has their SDKs and
   destinations installed; oldest-target and device/relaunch coverage remain
   platform-specific follow-up work.

## Deliberate non-goals

- A custom HTTP/2, HTTP/3, QUIC, TLS, cookie, or redirect implementation.
- A mandatory offline queue or global cache.
- GraphQL, gRPC, or product-specific authentication in the core target.
- Reachability preflight that blocks every request; use URLSession connectivity
  policies and the optional path observer instead.
