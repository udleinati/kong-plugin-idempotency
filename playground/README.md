# Idempotency playground

A self-contained, **DB-less** Kong setup to see the `idempotency` plugin working
end to end. No Postgres, no migrations, no custom image — the whole Kong config
lives in [`kong.yml`](./kong.yml) and the plugin source is mounted straight into
the stock `kong:3.9.2` image.

## What's inside

| Service | Role |
| --- | --- |
| `playground-kong` | Kong 3.9.2 (DB-less). Proxy on `:8000`, Admin API on `:8001`. |
| `playground-redis` | Redis 8 backing the idempotency cache. Exposed on `:6379`. |
| `playground-service` | Node echo upstream — returns JSON with a fresh random `id` per request. |

Routes pre-configured (see `kong.yml`):

- `/` — key **optional** (POSTs without the key pass through); default config.
- `/required` — key **required** (POSTs without the key get `400`).
- `/shortttl` — 2-second TTL, for the cache-expiry probe.
- `/multi` — idempotency on `POST/PUT/PATCH/DELETE`.
- `/strict` — `fail_open=false`: rejects with `503` when Redis is down.

## Run it

```bash
cd playground
docker compose up -d        # start Kong + Redis + echo service

./show-config.sh            # show how Kong is configured (kong.yml + Admin API)
./demo.sh                   # step-by-step walkthrough + assertions
./edge.sh                   # adversarial / edge-case probes

docker compose down         # stop everything
```

`demo.sh` is also a smoke test: it prints each request, its response and the
expected result, and exits non-zero if anything diverges.

### `edge.sh` — adversarial probes

Tries to break the plugin and labels each result `PASS` / `NOTE` (works as
designed, but a gotcha) / `BUG`:

1. real concurrency: a duplicate fired while the original is in flight → `409`;
2. at-most-once: a burst of concurrent same-key requests calls the upstream once;
3. method scoping: `PUT` with a key is ignored (`NOTE` — only `POST` is handled);
4. path scoping: the same key on different paths does not collide (`NOTE`);
5. non-200 status is preserved and replayed (e.g. `201`);
6. error caching: a `500` is replayed for the whole window (`NOTE` — sticky 5xx);
7. custom upstream headers survive the cached replay;
8. TTL expiry on the short-TTL route reprocesses after the window;
9. an empty `X-Idempotency-Key` is treated as no key (no cross-request leak);
10. binary (non-UTF-8) bodies are cached and replayed byte-for-byte;
11. a key ending in `-response` does not collide with another key's cache slot;
12. an upstream failure releases the lock, so retries are not stuck on `409`;
13. a client disconnecting mid-flight still gets the cached result on retry;
14. reusing a key with a different body is rejected with `422` (fingerprint);
15. a `5xx` is not cached, so the retry reprocesses;
16. `PUT` is idempotent on the `/multi` route;
17. strict mode returns `503` when Redis is down (and fail-open passes through).

The echo upstream honours control headers used by these probes:
`X-Echo-Status`, `X-Echo-Delay`, `X-Echo-Header`, `X-Echo-Binary`,
`X-Echo-Gzip`, `X-Echo-Reset` (drops the connection mid-flight).

## What the demo shows

1. **First request** with `X-Idempotency-Key` → `200`, `X-Idempotency-Status: completed`.
2. **Duplicate** with the same key → the cached response (same upstream `id`),
   without calling the upstream again.
3. **No key** on the optional route → passed through (a new `id` every time).
4. **GET** → ignored (the plugin only acts on `POST`).
5. **No key** on `/required` → `400`.

## Poke around manually

```bash
# first request
curl -i -X POST localhost:8000/ -H 'X-Idempotency-Key: abc' -d '{}'
# same key again -> identical body, served from cache
curl -i -X POST localhost:8000/ -H 'X-Idempotency-Key: abc' -d '{}'

# inspect Redis
docker compose exec playground-redis redis-cli keys '*'
```

Edit `kong.yml` and `docker compose restart playground-kong` to try other
settings (e.g. `redis_cache_time`, `is_required`).
