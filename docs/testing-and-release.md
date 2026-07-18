# Testing, performance, and release

## Test layers

| Layer | Purpose | Preferred tool |
| --- | --- | --- |
| Request construction | URL, headers, encoding, status policy | Swift Testing + pure values |
| HTTP transport | URLSession success/failure/cancellation | `URLProtocol` fixture |
| File lifecycle | ownership, cleanup, commit boundary | injected `FileIOExecutor` |
| WebSocket behavior | FIFO, overflow, closure, cancellation | loopback server + mock transport |
| Service injection | deterministic business tests | actor `MockAPIClient` |
| Public API | protocol existentials and examples | compile-focused tests |
| Performance | bounded memory and algorithm regressions | dedicated regression suite |

Mock one logical service call. Do not make mock tests depend on URLSession's
internal retry attempt count; retry behavior belongs in transport tests.

## Local validation

Use a writable module-cache location in restricted environments:

```sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/afn-clang-module-cache \
    SWIFT_MODULECACHE_PATH=/private/tmp/afn-swift-module-cache \
    swift test -Xswiftc -strict-concurrency=complete \
      -Xswiftc -warnings-as-errors
```

For a public API change, also run:

```sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/afn-clang-module-cache \
    SWIFT_MODULECACHE_PATH=/private/tmp/afn-swift-module-cache \
    swift build -c release --enable-parseable-module-interfaces \
      -Xswiftc -enable-library-evolution \
      -Xswiftc -strict-concurrency=complete \
      -Xswiftc -warnings-as-errors
```

The CI workflow should additionally cover the oldest deployment targets,
distribution builds, simulator execution, and forward-looking Swift
concurrency flags. The checked-in workflow runs the forward
`NonisolatedNonsendingByDefault` build, generic iOS/macOS distribution builds,
and the package test suite on the first installed iOS simulator. The local
`NWListener` WebSocket loopback fixture is skipped only on that simulator run
because iOS Simulator does not provide the listener NECP entitlement; mock
WebSocket coverage still runs there and the real loopback suite runs on macOS.
Simulator tests are explicitly serialized to avoid cooperative-executor
starvation in cancellation-heavy Swift Testing cases on hosted runners.

Physical-device background execution is a separate release gate. Follow
[Device and relaunch validation](device-validation.md) for signed host-app
scenarios; hosted CI must not be cited as proof that an OS-terminated app
received background callbacks or committed a protected destination.

## Performance gates

Performance tests should measure a budget, not merely execute a large input.
Track at least:

- allocations and peak memory for multipart and response handling;
- time to construct long URLs and normalized headers;
- stream throughput with a bounded consumer;
- WebSocket FIFO ordering under concurrent producer/consumer pressure;
- file cleanup latency under cancellation.

Avoid adding logging, Observation, metrics, or actor hops to the default hot
path. New buffers must state their maximum size and overflow behavior.

## Pull request checklist

Each PR should be small enough to review independently and include:

- one user-visible capability or one invariant-preserving refactor;
- focused tests plus the full strict suite result;
- README/docs updates for public behavior;
- migration notes for source or binary compatibility changes;
- security and privacy impact (tokens, URLs, bodies, files);
- release/library-evolution validation when public API changes;
- no unrelated formatting or generated artifacts.

## Release checklist

1. Confirm the package products and deployment targets.
2. Run strict Debug and Release tests.
3. Run library-evolution and forward-concurrency builds.
4. Review public API diffs and deprecations.
5. Update changelog, migration notes, and security guidance.
6. Tag a semantic version only after all required PR checks are green.
