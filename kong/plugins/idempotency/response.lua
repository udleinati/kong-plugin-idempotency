local cache = require "kong.plugins.idempotency.cache"
local keys = require "kong.plugins.idempotency.keys"
local scope = require "kong.plugins.idempotency.scope"
local payload = require "kong.plugins.idempotency.payload"
local lifecycle = require "kong.plugins.idempotency.lifecycle"

local kong = kong

local KEY_HEADER = "X-Idempotency-Key"
local STATUS_HEADER = "X-Idempotency-Status"

local _M = {}

function _M.execute(conf, version, client)
  -- Only the Original request (the one that won the NX lock in the access
  -- phase) persists the response. Duplicates are served from the cache in the
  -- access phase and passthrough requests never reach here.
  if not lifecycle.is_original(kong.ctx.plugin) then
    return
  end

  local status = kong.service.response.get_status()

  -- Do not cache server errors unless explicitly enabled: leave ctx.cached
  -- unset so the log phase frees the lock and the client can retry.
  if not conf.cache_5xx and status >= 500 then
    cache.release(client)
    return
  end

  kong.response.set_header(STATUS_HEADER, "completed")

  if not client then
    kong.log.err("idempotency: no Redis connection; response not cached")
    return
  end

  local idempotency_key = kong.request.get_header(KEY_HEADER)
  local req = scope.from_request()

  local encoded = payload.encode({
    status = status,
    body = kong.service.response.get_raw_body(),
    headers = kong.response.get_headers(),
  })

  local response_key = keys.response_key(conf, req, idempotency_key)

  local ok, err = client:set(response_key, encoded, "EX", conf.redis_cache_time)
  if ok then
    -- Tell the log phase the response was persisted, so it keeps the lock.
    lifecycle.cached(kong.ctx.plugin)
  else
    kong.log.err("idempotency: failed to cache response in Redis: ", err)
  end

  cache.release(client)
end

return _M
