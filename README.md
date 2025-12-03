# Kong Plugin Idempotency

A Kong plugin that enables idempotency to HTTP POST.

## Description

This plugin set a `nx` key on redis database for each `x-idempotency-key` came from the client, when the same `x-idempotency-key` came in other request throws error because the keys is already set on redis.

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
$ curl -X POST http://kong:8001/apis/{api}/plugins \
    --data "name=idempotency" \
    --data "config.redis_host=my_redis_server" \
    --data "config.redis_port=6379" \
    --data "config.redis_cache_time=10000"
```

| Parameter | default | description |
| ---       | ---     | ---         |
| `config.redis_host` | [required] | Host of redis server. |
| `config.redis_port` | [required] | Port of redis server. |
| `config.redis_cache_time` | [required] | Caches expiration time in seconds. |
| `config.is_required` | false | Define if idempotency is required, when is `false` it is possible to send request without `x-idempotency-key`. |
