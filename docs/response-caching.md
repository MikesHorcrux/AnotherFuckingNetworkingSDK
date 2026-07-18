# Response caching

`CachedAPIClient` adds an explicit, bounded in-memory cache for successful
typed responses. It uses caller-provided keys, TTL expiration, LRU eviction,
and a byte budget. Completed responses remain only in the decorator that owns
the cache; there is no process-wide cache.

```mermaid
flowchart TD
    Request --> Key{"Key and policy enabled?"}
    Key -- no --> Network["Base API client"]
    Key -- yes --> Hit{"Fresh cache entry?"}
    Hit -- yes --> Return["Return typed response"]
    Hit -- no --> Revalidate{"Stale validator?"}
    Revalidate -- no --> Network["Base API client"]
    Revalidate -- yes --> Conditional["If-None-Match / If-Modified-Since"]
    Conditional --> NotModified{"304?"}
    NotModified -- yes --> Refresh["Refresh TTL and return cached value"]
    NotModified -- no --> Store
    Network --> Store["Store successful response"]
    Store --> Evict["TTL / LRU / byte bound"]
    Evict --> Return
```

```swift
let client = CachedAPIClient(
    client: apiClient,
    policy: ResponseCachePolicy(
        maximumEntries: 128,
        maximumBytes: 8 * 1_024 * 1_024,
        timeToLive: 60
    ),
    keyProvider: { request in
        guard let request = request as? ProfileRequest else { return nil }
        return "profile:\(request.id):\(request.locale.identifier)"
    }
)
```

Keys must include the request type and every response-varying input, including
authorization scope, locale, feature flags, and body semantics. Return `nil`
for requests that must always hit the network. Only successful responses are
stored; failures and cancellation are never cached.

For HTTP-aware revalidation, use `ConditionalCachedAPIClient` with the same
bounded policy and key provider:

```swift
let client = ConditionalCachedAPIClient(
    client: apiClient,
    policy: ResponseCachePolicy(timeToLive: 60),
    keyProvider: { request in
        (request as? ProfileRequest).map { "profile:\($0.id)" }
    }
)
```

The decorator stores an `ETag` first, falling back to `Last-Modified`, and
caps retained validator values at 1 KiB. Once an entry is stale, it sends the
corresponding conditional request. A `304 Not Modified` returns the previously
decoded response and refreshes its TTL. Pagination methods are forwarded; use
`sendResponse(_:)` when applying the decorator to a paginated request.

Writes do not invalidate reads automatically. After a successful mutation,
invalidate the affected key or clear the decorator:

```swift
await client.invalidate("profile:42:en_US")
await client.removeAllCachedResponses()
```

Compose `CachedAPIClient` outside `RequestCoalescingAPIClient` when a cache miss
should also share one in-flight request:

```swift
let coalesced = RequestCoalescingAPIClient(client: cached) { request in
    // Return the same complete key used by the cache.
    cacheKey(for: request)
}
```

The cache remains opt-in and caller-keyed. Mutations do not invalidate reads
automatically; invalidate affected keys after a successful write.
