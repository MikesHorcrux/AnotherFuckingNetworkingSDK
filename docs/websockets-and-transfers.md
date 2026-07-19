# WebSockets and transfers

## WebSocket lifecycle

`APIClient.connect` builds the handshake from the same base URL, global
headers, cookies, and URLSession as HTTP requests. After the upgrade, one
receive pump owns transport reads and publishes messages to bounded FIFO
storage.

```mermaid
stateDiagram-v2
    [*] --> Connecting
    Connecting --> Open: upgrade accepted
    Connecting --> Failed: rejected upgrade or transport error
    Open --> Open: send / receive / ping
    Open --> Closing: close requested
    Open --> Failed: transport failure
    Closing --> Closed: close handshake completes
    Failed --> Closed: transport cancelled
    Closed --> [*]
```

The inbound buffering policy is captured when the connection opens. Overflow
fails closed rather than silently dropping messages. The connection state
sequence is bounded and Observation adapters mirror it when available.

The base connection deliberately does not reconnect or schedule heartbeats.
Those behaviors depend on product semantics (authentication, foreground state,
backoff, subscriptions) and belong in an application or policy wrapper.

## Message ownership

- A caller may send concurrently; the transport serializes URLSession task
  interaction as required by the connection state machine.
- Only the internal receive pump reads from the URLSession task.
- Consumers receive messages in FIFO order.
- Cancellation of a receive closes the connection and preserves
  `CancellationError`.
- Close is idempotent; peer close details remain available in lifecycle state.

## Foreground file transfers

```mermaid
sequenceDiagram
    participant Caller
    participant Client
    participant URLSession
    participant Filesystem

    Caller->>Client: upload(file) or download(destination)
    Client->>Client: validate source/destination
    Client->>URLSession: start transfer task
    URLSession-->>Client: response + temporary file
    Client->>Client: validate status
    Client->>Filesystem: serialized move/replace
    Filesystem-->>Caller: owned destination URL
```

Foreground downloads move Foundation's temporary file into `.temporary` or a
caller-selected `.file` destination. The SDK never deletes an upload source.
Failed response bodies are bounded; successful downloads are never loaded into
memory.

## Background and resumable roadmap

Background URLSession support is intentionally a separate lifecycle-bound
product. A complete implementation must persist transfer identity, rebind a
delegate after app relaunch, handle the system-provided background completion
handler, and expose resume data. Do not advertise foreground downloads as
relaunch-safe. See [Roadmap](roadmap.md) for the planned module boundary.
