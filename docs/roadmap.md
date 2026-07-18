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
  progress, resume-data extraction, and relaunch completion callbacks.
- `StreamingMultipartFormData` for bounded file-backed multipart uploads.
- Opt-in operation and attempt telemetry with privacy-safe exporter events.
- Transfer delegate task-metrics telemetry with privacy-safe snapshots.
- Bounded WebSocket receive pump, lifecycle state, Observation adapters, and
  loopback fixtures.
- Opt-in WebSocket reconnect, bounded backoff, heartbeat, and session-restorer
  policies.
- Redacted logging, privacy-safe activity snapshots, and actor-based mocks.
- Validator-aware conditional caching with bounded `ETag`/
  `Last-Modified` revalidation.

## Next production modules

1. **Platform background/resumable integration** — device/relaunch coverage,
   resume-data validation, and coordinator routing for the shipped
   `BackgroundURLSessionAdapter` on each supported Apple platform.
2. **Platform task-metrics integration** — wire the shipped snapshot into any
   remaining platform delegate operations and oldest-target coverage where the
   platform exposes metrics.
3. **Streaming multipart integration** — broader upload retry, signing, and
   oldest-target coverage for the shipped file-backed encoder.
4. **WebSocket platform hardening** — server-specific cursor/session recovery
   adapters and oldest-target integration coverage.
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
  policies and optional path observation instead.
