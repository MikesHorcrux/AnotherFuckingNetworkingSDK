# Changelog

All notable changes to `AnotherFuckingNetworkingSDK` are documented here.
Entries describe public behavior and release evidence; a version is not
considered released until it is tagged after the checks in
[`docs/testing-and-release.md`](docs/testing-and-release.md) pass.

## Unreleased — 2.0.0 modernization

This branch contains the Swift 6 modernization and production networking
platform work. It is intentionally unreleased until the stacked pull requests
are merged and the physical-device/background gate is completed by an
integrating host app.

### HTTP and streaming

- Swift 6 strict-concurrency HTTP with synchronized configuration snapshots,
  typed responses, raw payloads, metadata, pagination, status policies,
  cancellation preservation, and opt-in replay-safe retries.
- Single-pass bounded HTTP byte streams.
- A global final-request customization hook for correlation IDs, tracing,
  signing, user-agent policy, and other application-wide HTTP request policy.
- Bounded Server-Sent Events streams with UTF-8 validation, LF/CRLF framing,
  multiline data, IDs, event names, and retry metadata.
- Typed JSON Lines/NDJSON streams with bounded records and cancellation-safe
  iteration.

### Policy composition

- Single-flight request coalescing and bounded response caching with optional
  validator revalidation.
- Actor-isolated circuit breaking with injectable clocks and failure
  classification.
- Actor-isolated FIFO request concurrency limiting with bounded waiters,
  cancellation-aware queue removal, and a response-client decorator.
- Single-flight authentication refresh with idempotency-aware 401 replay.

### Transfers and lifecycle

- File-backed uploads, streaming multipart bodies, foreground downloads,
  progress, durable transfer jobs, and actor-isolated lifecycle coordination.
- Background URLSession task descriptors, relaunch reconciliation, collision
  diagnostics, typed pause/cancel/resume controls, bounded resume data, and
  validated download task creation.
- Format-agnostic resume-data validation with opt-in property-list integrity
  checks.

### WebSockets and diagnostics

- Bounded receive FIFO, lifecycle state streams, Observation adapters,
  cancellation-safe WebSocket operations, and loopback coverage.
- Opt-in reconnect, heartbeat, contextual restoration, durable recovery stores,
  typed recovery codecs, and typed JSON/binary message codecs.
- Privacy-safe activity monitoring, telemetry, task metrics, logging, network
  path observation, and actor-based testing fixtures.

### Evidence and release gates

- Strict Swift 6 Debug/Release test coverage and library-evolution builds.
- CI coverage for iOS, macOS, iOS Simulator, additional installed Apple
  platforms, and Mac Catalyst.
- Physical-device background execution, OS termination, protected storage,
  relaunch, and radio-transition validation remain a host-app release gate;
  see [`docs/device-validation.md`](docs/device-validation.md).

## Release process

1. Merge the small capability PRs only after their hosted checks are green.
2. Run the full local strict suite, Release build, and library-evolution build.
3. Complete the signed host-app device/relaunch scenarios and attach the
   evidence described in the device-validation runbook.
4. Update this file with the final tag date and migration notes.
5. Tag the semantic version and publish the generated release notes.
