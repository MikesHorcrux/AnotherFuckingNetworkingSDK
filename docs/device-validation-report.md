# Local device validation report

This report records the strongest validation that can be produced from the
current development workstation. It is evidence for build and simulator
compatibility; it is not a substitute for an app-hosted background lifecycle
run.

## Run

- Date: 2026-07-18
- SDK head: `e3cb450` (`Mike/host-app-harness`)
- Toolchain: Xcode 26.2 / Swift 6 language mode
- Physical target: paired iPad Air 13-inch (M3), iOS 26.6 beta
- Simulator target: not rerun in this evidence refresh

## Results

| Check | Command/result | Evidence level |
| --- | --- | --- |
| Strict host suite | `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` — 357 tests in 42 suites passed in Debug and Release | Strong unit/integration evidence |
| Signed-host fixture compile | `xcodebuild ... BackgroundTransferHost ... generic/platform=iOS CODE_SIGNING_ALLOWED=NO` — exit 0 in Release with strict concurrency | Strong compile evidence; no runtime claim |
| iOS simulator suite | Prior simulator evidence remains recorded below; this change was validated as a generic device product build, not a simulator runtime | Existing simulator evidence |
| Physical host-app build | Signed build targeted the paired iPad but stopped before compilation because Xcode has no valid account or provisioning profile for `com.anotherfuckingnetworkingsdk.background-host` | Missing signing evidence |
| Physical package tests | Not executable: SwiftPM test targets have no host application, and Xcode reports tool-hosted testing is unavailable on device destinations | Missing runtime evidence |
| OS termination/background relaunch | Not executed; requires a signed host app, background session identifier, durable storage, and app lifecycle callbacks | Missing lifecycle evidence |

The existing simulator run specifically validates the WebSocket receive
synchronization path that previously failed on hosted CI. The host suites now
also cover the delegate-backed task-metrics paths for ordinary HTTP requests
and HTTP byte streams. The new host fixture compiles for a generic iOS device,
but signing is required before it can exercise protected files, radio
transitions, or process relaunch.

## Current device availability check

On 2026-07-19 UTC, CoreDevice reported the paired iPad as available and
paired, with developer mode enabled, DDI services available, and its developer
tunnel connected. The paired iPhone remains unavailable. A signed build still
requires an Xcode account or a provisioning profile matching the host bundle
identifier and development certificate; that credential is not present on this
workstation.

## Release interpretation

The SDK and host fixture are ready for merge-level source, strict-concurrency,
simulator, and unsigned device-build review. Keep the physical
background/relaunch release gate open until an integrating app signs the host
and captures the scenarios in
[device-validation.md](device-validation.md) with the debugger detached.
