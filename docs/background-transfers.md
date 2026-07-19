# Background and resumable transfers

The foreground `APIClient` transfer methods are intentionally simple and
durable at the file-ownership boundary. A background transfer has a second
problem: queue identity must survive process termination, while the request
value and platform session delegate remain application-owned. The SDK provides
the persistence and state-machine seam without pretending that a foreground
`URLSession` can continue after termination.

## Durable model

`TransferJob` is a `Codable`, `Sendable` record containing a stable UUID,
application-defined `requestKey`, direction, state, progress checkpoint,
optional resume data, destination URL, and the last error description. The
request key is deliberately opaque: on relaunch, resolve it from your own
database or dependency container rather than serializing arbitrary request
types.

```mermaid
stateDiagram-v2
    [*] --> queued
    queued --> running: execute(id:operation:)
    running --> running: checkpoint progress
    running --> succeeded: operation returns
    running --> paused: task cancellation
    running --> failed: operation throws
    paused --> running: caller resumes
    failed --> running: caller retries
    succeeded --> [*]
    queued --> cancelled: cancel(id:)
    paused --> cancelled: cancel(id:)
    cancelled --> [*]
```

`TransferJobCoordinator` persists each lifecycle boundary through
`TransferJobStore`. `InMemoryTransferJobStore` is useful for tests; use
`JSONTransferJobStore` for a small app-owned index. JSON writes are atomic and
run on the SDK's utility file-I/O queue.

## Integrating a background session

`BackgroundURLSessionAdapter` owns the Foundation background session and
translates delegate callbacks into `BackgroundTransferEvent` values. It is
intentionally request-agnostic: the application still resolves `requestKey`,
adds current credentials, and commits downloaded files.

```swift
let adapter = BackgroundURLSessionAdapter(
    identifier: "com.example.exports",
    eventHandler: { event in
        Task { await backgroundEventRouter.handle(event) }
    }
)

adapter.setBackgroundEventsCompletionHandler {
    applicationCompletionHandler()
}

let task = adapter.download(
    requestURLRequest,
    resumeData: job.resumeData,
    jobID: job.id
)
```

Passing `jobID` stores a namespaced, opaque task description. On relaunch,
reconcile Foundation's still-running tasks with the durable job index before
handling delegate events:

```swift
for task in await adapter.transferTasks() {
    guard let jobID = task.jobID else { continue }
    // Bind task.taskIdentifier to jobID in the app-owned event router.
}
```

`BackgroundTransferEvent.taskIdentifier` is available on every task-scoped
event, while `backgroundEventsFinished` has no task identifier. This makes it
possible to route progress, metrics, temporary files, and completion events
after process termination without persisting requests or credentials.

```mermaid
sequenceDiagram
    participant App
    participant Store as TransferJobStore
    participant Session as Background URLSession
    App->>Store: restore jobs
    App->>Session: transferTasks()
    Session-->>App: taskIdentifier + jobID descriptors
    App->>App: bind identifiers to jobs
    Session-->>App: BackgroundTransferEvent
    App->>Store: persist checkpoint or terminal state
```

The delegate emits bounded progress, temporary download locations, completion
errors, opaque resume data, privacy-safe task-metrics snapshots, and a final
`backgroundEventsFinished` event. The system completion handler is invoked only
after that terminal event. Keep the adapter alive for the session's lifetime
and route events to the coordinator.

The operation closure is the bridge to the application or a future dedicated
background product. It receives the restored job and a checkpoint callback.
Checkpoint data can contain `URLSession` resume data or another bounded,
application-defined token.

```swift
let store = JSONTransferJobStore(fileURL: jobsURL)
let coordinator = TransferJobCoordinator(store: store)
try await coordinator.restore()

let job = TransferJob(
    kind: .download,
    requestKey: "export-42",
    destinationURL: destinationURL
)
try await coordinator.enqueue(job)

let finished = try await coordinator.execute(id: job.id) { job, checkpoint in
    let request = try await requestResolver(job.requestKey)
    let response = try await backgroundSession.download(
        request,
        resumeData: job.resumeData,
        progress: { progress, resumeData in
            Task {
                try? await checkpoint(TransferJobUpdate(
                    progress: progress,
                    resumeData: resumeData,
                    destinationURL: job.destinationURL
                ))
            }
        }
    )
    return TransferJobResult(
        bytesCompleted: response.bytesCompleted,
        totalBytes: response.totalBytes,
        destinationURL: response.fileURL
    )
}
```

The `backgroundSession` in this example can be the adapter above or another
application-owned implementation. The coordinator owns durable job state and
must remain the single writer for that state. Validate resume data before
resuming and move a finished temporary file to its destination before marking
the job succeeded.

## Cancellation and relaunch

Cancel the task awaiting `execute` to pause a running transfer. The coordinator
stores `.paused` and preserves the last checkpoint before rethrowing
`CancellationError`. A queued or paused job can be marked `.cancelled` with
`cancel(id:)`; running jobs must be cancelled through their executing task so
the transport receives the same cancellation signal.

On launch, call `restore()`, inspect `snapshot()`, resolve queued/paused jobs,
and execute them with a newly rebound session delegate. Do not automatically
resume every record without applying current authentication, destination, and
data-retention policy.

## Safety rules

- Keep resume data bounded and treat it as sensitive opaque transport state.
  `TransferJob` and `JSONTransferJobStore` enforce the same 8 MiB bound at
  construction and restore time.
- Failed job records retain only a bounded NSError domain/code identity; do not
  persist localized error text or response payloads in durable state.
- Never delete an upload source as part of pause, retry, or cancellation.
- Do not mark a job succeeded until the destination commit has completed.
- Persist a checkpoint before waiting on long application-level work.
- Keep system background completion handlers separate from transfer progress
  callbacks; call the handler only after all delegate work is drained.
- Test relaunch and duplicate delegate callbacks with a real background-session
  integration target on each supported Apple platform.

The adapter is available on the package's iOS 15/macOS 12 baseline. It is
intentionally unavailable on tvOS, watchOS, and visionOS because their
background URLSession lifecycle contracts differ; use the durable coordinator
with a platform-owned transfer implementation there. Platform behavior still
needs device/relaunch integration coverage, and APIs may differ; keep those
checks in the application lifecycle target.
