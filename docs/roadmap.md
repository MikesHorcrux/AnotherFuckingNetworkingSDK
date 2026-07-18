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
- Opt-in operation and attempt telemetry with privacy-safe exporter events.
- Bounded WebSocket receive pump, lifecycle state, Observation adapters, and
  loopback fixtures.
- Opt-in WebSocket reconnect, bounded backoff, heartbeat, and session-restorer
  policies.
- Redacted logging, privacy-safe activity snapshots, and actor-based mocks.

## Next production modules

1. **Platform background/resumable adapters** — background URLSession delegate
   rebinding, system completion handlers, resume-data validation, and relaunch
   integration on each supported Apple platform.
2. **Platform task-metrics adapters** — delegate-backed URLSession metrics
   capture where each platform/API exposes it.
3. **Streaming multipart** — file-backed parts and bounded encoding.
4. **WebSocket platform hardening** — server-specific cursor/session recovery
   adapters and oldest-target integration coverage.
5. **Caching and request coalescing** — conditional requests and explicit cache
   policy, without imposing application-wide cache semantics.
6. **Platform matrix** — oldest-target builds plus tvOS, watchOS, visionOS, and
   Catalyst evaluation.

## Deliberate non-goals

- A custom HTTP/2, HTTP/3, QUIC, TLS, cookie, or redirect implementation.
- A mandatory offline queue or global cache.
- GraphQL, gRPC, or product-specific authentication in the core target.
- Reachability preflight that blocks every request; use URLSession connectivity
  policies and optional path observation instead.
