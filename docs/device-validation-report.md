# Local device validation report

This report records the strongest validation that can be produced from the
current development workstation. It is evidence for build and simulator
compatibility; it is not a substitute for an app-hosted background lifecycle
run.

## Run

- Date: 2026-07-18
- SDK head: `b148b9f` (`Mike/stream-task-metrics`)
- Toolchain: Xcode 26.2 / Swift 6 language mode
- Physical target: paired iPad Air 13-inch (M3), currently locked
- Simulator target: not rerun in this evidence refresh

## Results

| Check | Command/result | Evidence level |
| --- | --- | --- |
| Strict host suite | `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` — 357 tests in 42 suites passed in Debug and Release | Strong unit/integration evidence |
| Signed-host fixture compile | `xcodebuild ... BackgroundTransferHost ... generic/platform=iOS CODE_SIGNING_ALLOWED=NO` — exit 0 in Release with strict concurrency | Strong compile evidence; no runtime claim |
| iOS simulator suite | Prior simulator evidence remains recorded below; no new simulator run was needed for this documentation-only refresh | Existing simulator evidence |
| Physical product build | No new device product build; the paired iPad was locked and its developer tunnel was unavailable | Missing device-build evidence for this refresh |
| Physical package tests | Not executable: SwiftPM test targets have no host application, and Xcode reports tool-hosted testing is unavailable on device destinations | Missing runtime evidence |
| OS termination/background relaunch | Not executed; requires a signed host app, background session identifier, durable storage, and app lifecycle callbacks | Missing lifecycle evidence |

The existing simulator run specifically validates the WebSocket receive
synchronization path that previously failed on hosted CI. The host suites now
also cover the delegate-backed task-metrics paths for ordinary HTTP requests
and HTTP byte streams. Neither host nor simulator evidence exercises protected
files, radio transitions, or process relaunch.

## Current device availability check

On 2026-07-18, CoreDevice reported the paired iPad as physically present but
locked, with its developer tunnel disconnected. The paired iPhone was
unavailable. This is a device-state limitation, not a package compilation
failure; retry the device build and the signed host-app scenarios after a
device is unlocked and its developer tunnel is connected.

## Release interpretation

The SDK is ready for merge-level source, strict-concurrency, simulator, and
device-build review. Keep the physical background/relaunch release gate open
until an integrating app captures the scenarios in
[device-validation.md](device-validation.md) with the debugger detached.
