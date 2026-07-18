# Local device validation report

This report records the strongest validation that can be produced from the
current development workstation. It is evidence for build and simulator
compatibility; it is not a substitute for an app-hosted background lifecycle
run.

## Run

- Date: 2026-07-18
- SDK head: `dd3e801` (`Mike/release-changelog`)
- Toolchain: Xcode 26.2 / Swift 6 language mode
- Physical target: connected iPhone (`Mike ’s iPhone`)
- Simulator target: iPhone 16e, iOS 26.3.1

## Results

| Check | Command/result | Evidence level |
| --- | --- | --- |
| Strict host suite | `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors` — 353 tests in 42 suites passed | Strong unit/integration evidence |
| iOS simulator suite | `xcodebuild ... -destination id=50D6FAE6-F278-43D3-9264-8B28A21C9836 test` with the loopback suite skipped — exit 0 | Strong simulator evidence |
| Physical iPhone product build | Release package build for `id=00008140-001410183490801C` with signing disabled — exit 0 | Strong compile/link evidence |
| Physical iPhone package tests | Not executable: SwiftPM test targets have no host application, and Xcode reports tool-hosted testing is unavailable on device destinations | Missing runtime evidence |
| OS termination/background relaunch | Not executed; requires a signed host app, background session identifier, durable storage, and app lifecycle callbacks | Missing lifecycle evidence |

The simulator run specifically validates the WebSocket receive synchronization
path that previously failed on hosted CI. The physical build confirms that the
public package compiles and links for the device architecture, but it does not
exercise URLSession delegates, protected files, radio transitions, or process
relaunch.

## Current device availability check

On 2026-07-18, CoreDevice reported the paired iPad as physically present but
locked, with its developer tunnel disconnected. `xcodebuild` therefore timed
out while preparing the destination and did not produce a new device runtime
result. The paired iPhone was reported unavailable. This is a device-state
limitation, not a package compilation failure; retry the device build and the
signed host-app scenarios after the device is unlocked and the developer
tunnel is connected.

## Release interpretation

The SDK is ready for merge-level source, strict-concurrency, simulator, and
device-build review. Keep the physical background/relaunch release gate open
until an integrating app captures the scenarios in
[device-validation.md](device-validation.md) with the debugger detached.
