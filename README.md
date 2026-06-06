# Kong Plugin Idempotency

A Kong plugin that adds **idempotency** to HTTP `POST` requests, backed by Redis.

## Description

Clients send an `X-Idempotency-Key` header with their `POST` request. The plugin
guarantees that, for a given key, the request is processed **at most once**: the
first request is proxied to the upstream and its response is cached in Redis;
any later request carrying the same key replays that cached response instead of
hitting the upstream again.

This makes it safe for clients to retry `POST` requests (network blips, timeouts,
double-clicks) without creating duplicate side effects.

### How it works

For each eligible request the plugin uses an atomic Redis `SET key 1 NX EX <ttl>`
to claim a per-key lock:

1. **First request wins the lock** → it is proxied normally. In the `response`
   phase the upstream status, body and headers are stored in Redis under a
   `…-response` key with the configured TTL. The client gets the response with
   `X-Idempotency-Status: completed`.
2. **A duplicate arrives while the first is still in flight** (lock held, no
   cached response yet) → the client gets `409` with
   `X-Idempotency-Status: waiting_response`, signalling it to retry shortly.
3. **A duplicate arrives after the first finished** → the cached response is
   replayed verbatim with `X-Idempotency-Status: completed`.

Keys are namespaced as `[<redis-username>::]<redis_prefix>:<path>:<method>:<key>`,
so the same idempotency key on different routes/users never collides.

> **Resilience:** if Redis is unreachable the plugin *fails open* — the request
> is proxied normally (a warning is logged) rather than taking the protected
> service down. The idempotency guarantee is lost for the duration of the
> outage.

## Installation

```bash
$ luarocks install kong-plugin-idempotency
```

Update the `plugins` config to add `idempotency`:

```
plugins = bundled,idempotency
```

## Configuration

```bash
$ curl -X POST http://kong:8001/services/{service}/plugins \
    --data "name=idempotency" \
    --data "config.redis.host=my_redis_server" \
    --data "config.redis.port=6379" \
    --data "config.redis_cache_time=86400"
```

Send requests with the key:

```bash
$ curl -X POST http://kong:8000/orders \
    -H "X-Idempotency-Key: 7e3f…" \
    -d '{"amount": 100}'
```

| Parameter | default | description |
| ---       | ---     | ---         |
| `config.is_required` | `false` | When `false`, requests without an `X-Idempotency-Key` are passed through untouched. When `true`, such requests are rejected with `400`. |
| `config.redis_cache_time` | `86400` | TTL (in seconds) of the idempotency lock and the cached response — i.e. the window during which a key is treated as a duplicate. Must be > 0. |
| `config.redis_prefix` | `kong-idempotency-plugin` | Namespace prepended to every Redis key. |
| `config.redis.host` | | **Mandatory.** Redis host. |
| `config.redis.port` | `6379` | |
| `config.redis.password` | | Referenceable (vault). |
| `config.redis.username` | | Referenceable (vault). Requires Redis 6.0.0+. Also scopes the Redis keys. |
| `config.redis.ssl` | `false` | |
| `config.redis.ssl_verify` | `false` | |
| `config.redis.server_name` | | SNI used for the TLS handshake. |
| `config.redis.timeout` | `2000` | Socket timeout in ms. |
| `config.redis.database` | `0` | |

> The Redis config uses Kong's shared `config.redis.*` record (Kong 3.6+). The
> legacy flat fields (`config.redis_host`, `config.redis_port`,
> `config.redis_password`, …) are still accepted for backwards compatibility and
> are folded into `config.redis.*`.

### Response headers

| Header | values | meaning |
| --- | --- | --- |
| `X-Idempotency-Status` | `completed` | The response is the (cached or freshly produced) result for this key. |
| `X-Idempotency-Status` | `waiting_response` | The original request for this key is still in flight (returned with `409`). |

## Development & Testing

The plugin is covered by two test suites under `spec/`:

- `spec/01-unit` — fast, fully-mocked unit tests for every module
  (`keys`, `cache`, `access`, `response`, `handler`). No Kong/network needed.
- `spec/02-integration` — end-to-end tests that boot a real Kong + Redis,
  validate the schema and exercise the full flow (first request, cache replay,
  in-flight `409`, required key, passthrough, legacy config).

Tests run inside [Pongo](https://github.com/Kong/kong-pongo), Kong's official
test runner (requires Docker). The provided `Makefile` vendors Pongo locally on
first use:

```bash
make test                  # luacheck + the whole suite
make unit                  # only spec/01-unit
make integration           # only spec/02-integration (needs Redis, provided by Pongo)
make lint                  # luacheck only
make test KONG_VERSION=3.6.1   # pin a specific Kong version
```

CI runs the same suite across Kong 3.6.1 / 3.8.0 / 3.9.2 (see
`.github/workflows/test.yml`). A local [`playground`](./playground) (Docker
Compose) is also provided.

## Notes & possible improvements

- **Lock vs. response TTL.** The lock and the cached response currently share a
  single TTL. If the original request never produces a cached response (e.g. the
  upstream or Kong dies before the `response` phase), duplicates receive `409`
  for the whole `redis_cache_time` window. A shorter lock TTL — or releasing the
  lock on an upstream `5xx` — would let clients retry sooner.
- **Caching of error responses.** Every status code is cached, so a transient
  upstream failure becomes "sticky" for the window. Restricting caching to, say,
  `2xx`/`4xx` could be made configurable.
- **Methods beyond POST.** Idempotency keys are also useful for `PUT`/`PATCH`/
  `DELETE`; the plugin is intentionally `POST`-only today.

## Author

Udlei Nati - [GitHub](https://github.com/udleinati "GitHub") - [LinkedIn](https://www.linkedin.com/in/udleinati/ "LinkedIn")
