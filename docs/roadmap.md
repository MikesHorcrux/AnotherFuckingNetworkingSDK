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
- Bounded WebSocket receive pump, lifecycle state, Observation adapters, and
  loopback fixtures.
- Redacted logging, privacy-safe activity snapshots, and actor-based mocks.

## Next production modules

1. **Transfer progress events** — byte counts and expected lengths for uploads,
   downloads, and streams without adding work to clients that do not opt in.
2. **Background/resumable transfers** — separate product with persistent
   identity, delegate rebinding, resume data, and relaunch completion handling.
3. **Telemetry** — operation/attempt IDs, duration, bytes, task metrics, and an
   optional OpenTelemetry bridge.
4. **Streaming multipart** — file-backed parts and bounded encoding.
5. **WebSocket reliability policies** — reconnect, heartbeat, backoff, and
   session restoration as opt-in wrappers.
6. **Caching and request coalescing** — conditional requests and explicit cache
   policy, without imposing application-wide cache semantics.
7. **Platform matrix** — oldest-target builds plus tvOS, watchOS, visionOS, and
   Catalyst evaluation.

## Deliberate non-goals

- A custom HTTP/2, HTTP/3, QUIC, TLS, cookie, or redirect implementation.
- A mandatory offline queue or global cache.
- GraphQL, gRPC, or product-specific authentication in the core target.
- Reachability preflight that blocks every request; use URLSession connectivity
  policies and optional path observation instead.
