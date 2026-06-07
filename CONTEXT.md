# Idempotency

The domain language of the Kong idempotency plugin: how a client-supplied
`X-Idempotency-Key` is turned into an at-most-once guarantee backed by Redis,
across Kong's access → response → log phases.

## Request kinds

**Original**:
The request that won the `SET NX` race and owns the lock for its scope. It is
let through to the upstream and its response is cached for later duplicates.
_Avoid_: first request, owner, leader.

**Duplicate**:
A later request carrying the same idempotency key within the same **Scope**
while an **Original** still holds the lock. Served the cached response, told to
wait (409), or rejected on a fingerprint mismatch (422).
_Avoid_: retry, repeat.

**Passthrough**:
A request the plugin does not handle at all — wrong method, or no key when the
key is optional. Never touches Redis.
_Avoid_: ignored, skipped.

## Lifecycle

**Idempotency lifecycle**:
The states an **Original** moves through, owned by the `lifecycle` module over
`kong.ctx.plugin`: won-lock → cached, or won-lock → orphaned. The single source
of truth for "is this the original?" and "must this lock be freed?".
_Avoid_: state machine, flow, status.

**Orphaned lock**:
A **Lock** held by an **Original** that never cached a response (e.g. the
upstream failed, or a 5xx with `cache_5xx` off). Freed in the log phase so
**Duplicate**s are not stuck on 409 for the whole TTL.
_Avoid_: stale lock, dangling lock.

## Keys & storage

**Scope**:
The namespace a key is unique within: `consumer:host:path:method` (plus an
optional Redis-username prefix). Stops one client's key colliding with another
consumer/host/endpoint on a shared Redis. Built from the request, formatted by
the pure `keys` module.
_Avoid_: namespace, prefix, partition.

**Lock**:
The `SET NX EX` key marking an in-flight **Original**. Its value is the
**Fingerprint** (or `"1"` when fingerprinting is off).
_Avoid_: mutex, semaphore.

**Fingerprint**:
An md5 of the raw body + query string, stored as the **Lock** value, used to
reject a key reused with a *different* request (422).
_Avoid_: hash, digest, checksum.

**Cached payload**:
The stored `{ status, body, headers }` of an **Original**'s response, JSON
-encoded under the response key and replayed verbatim to **Duplicate**s.
Hop-by-hop and length headers are stripped before storing.
_Avoid_: cached response object, snapshot.

## Resilience

**Fail open**:
On a Redis outage, let requests through unguarded (the idempotency guarantee is
lost but traffic flows). The opposite — strict mode — rejects with 503.
_Avoid_: degrade, bypass, lenient mode.

## Example dialogue

> **Dev:** If two requests arrive with the same key at once, which one is the Original?
> **Expert:** Whichever wins the `SET NX`. That one holds the Lock for its Scope and goes upstream; the other is a Duplicate and gets a 409 until the response is cached.
> **Dev:** And if the Original's upstream crashes before caching?
> **Expert:** Then its Lock is Orphaned. The log phase asks the lifecycle whether to free it, and frees it — otherwise every Duplicate sits on 409 for the full TTL.
> **Dev:** What if the Duplicate's body differs from the Original's?
> **Expert:** The Fingerprint won't match the Lock value, so it's a 422, not a replay — same key, different request is a conflict.
