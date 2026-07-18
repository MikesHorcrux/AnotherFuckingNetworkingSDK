# Security and privacy

The SDK provides safe defaults and extension points; it cannot decide an
application's identity, credential, or server trust model. Treat this page as
an integration checklist, not as a replacement for a security review.

## Secrets

- Keep access and refresh tokens in Keychain or an equivalent secure store.
- Inject token loaders into `HTTPAuthenticator`; never put a token in a global
  `APIClient` header that can be copied into diagnostics.
- Do not include tokens, cookies, passwords, one-time codes, or signed URLs in
  request paths, error descriptions, analytics events, or test fixtures.
- Treat `HTTPFailure.data` as sensitive. Decode it only when the endpoint's
  contract permits and keep the SDK's bounded retention limit.

## Logging

`NetworkingLogger` redacts authorization, cookies, API keys, common token query
items, and sensitive JSON keys by default. Keep the default body policy
`.omitted` in production. If a development build includes redacted JSON,
configure a small byte limit and a narrow key allowlist. Never pass raw
`URLRequest` or response bodies to an untrusted sink.

## Transport security

- Use `https` for HTTP and `wss` for WebSockets outside local development.
- Keep App Transport Security enabled; add the narrowest documented exception
  for a development endpoint rather than disabling ATS globally.
- Let URLSession own TLS negotiation and authentication challenges by default.
- If certificate or public-key pinning is required, implement it through a
  task/session delegate with key rotation, backup pins, expiry, and an audited
  failure path. Do not silently accept a server-trust challenge.
- Do not implement a custom TLS or HTTP/3 stack in the SDK.

## URL and request construction

Request paths and query items are encoded through `URLComponents` and the
request path policy. Use `.percentEncoded` only when the endpoint provides a
validated encoded path. Avoid placing attacker-controlled strings in headers
or `customize(_:)` without validation.

## Authentication replay

Authentication replay is intentionally conservative: idempotent methods are
allowed by default, while mutations require `.explicitlyReplayable`. Use an
idempotency key and server-side deduplication before opting a mutation in.
Refresh once after a 401; do not build an unbounded refresh loop.

## Files and WebSockets

- Validate file URLs and destination ownership before starting transport.
- Store downloaded files in an app-controlled directory with appropriate file
  protection and remove temporary files after use.
- Bound WebSocket inbound buffering and fail closed on overflow.
- Do not log WebSocket message payloads unless the application has explicitly
  classified them as non-sensitive.

## Security review questions

1. Which component owns and rotates credentials?
2. Can any URL, header, body, or error reach logs or telemetry unsanitized?
3. Are ATS, TLS challenges, cookies, redirects, and pinning policies explicit?
4. Are replayable mutations protected by idempotency keys?
5. Are temporary files protected, cleaned, and excluded from backups when
   appropriate?
