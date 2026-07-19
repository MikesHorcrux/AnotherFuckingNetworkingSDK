# Background transfer host app

This signed iOS host is the runtime fixture for the SDK's background URLSession
integration. It is intentionally small: the app owns the durable JSON job
store, while `BackgroundTransferHost` owns the application lifecycle and the
SDK owns task routing, bounded resume data, metrics, and terminal state
transitions.

## Build

Open `BackgroundTransferHost.xcodeproj` in Xcode 16 or later. The project uses
the repository root as a local Swift package dependency. Select a real iOS
device, choose a development team, and enable signing for the
`BackgroundTransferHost` target.

The generic build gate can be run without signing:

```sh
xcodebuild \
  -project Examples/BackgroundTransferHost/BackgroundTransferHost.xcodeproj \
  -scheme BackgroundTransferHost \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Runtime validation

1. Install the signed app on an unlocked device with the developer tunnel
   connected.
2. Enter an HTTPS URL for a sufficiently large file and tap **Start**.
3. Lock the device or terminate the app from the app switcher while bytes are
   still transferring.
4. Wait for the system to relaunch the app, then verify the durable job is
   restored and progress continues.
5. Repeat with **Pause**, terminate the app, relaunch, and verify that bounded
   resume data is used to continue the same job.
6. Capture the final destination file, job state, task metrics, and
   `handleEventsForBackgroundURLSession` completion in the release evidence
   report.

The host deliberately uses `BackgroundTransferLifecycleCoordinator` rather
than mutating `TransferJob` records from delegate callbacks. That is the
reference pattern for an integrating application. The URLSession identifier
is stable across launches, and the app delegate forwards Apple's completion
handler to the SDK adapter only for that identifier.

The fixture creates each task suspended, binds its Foundation task identifier
to the durable job, and only then resumes it. That ordering prevents a fast
delegate callback from racing route registration.

This sample is a validation fixture, not a production download UI. Replace the
demo URL, add product authentication, and apply the application's file
protection policy before shipping it.
