local cjson = require "cjson"
local cache = require "kong.plugins.idempotency.cache"
local keys = require "kong.plugins.idempotency.keys"

local kong = kong

local KEY_HEADER = "X-Idempotency-Key"
local STATUS_HEADER = "X-Idempotency-Status"

-- Hop-by-hop / length headers must not be stored and replayed verbatim: the
-- body is re-sent on replay so Kong recomputes these. Keys are lowercase to
-- match `kong.response.get_headers()`.
local VOLATILE_HEADERS = {
  ["connection"] = true,
  ["content-length"] = true,
  ["transfer-encoding"] = true,
  ["x-idempotency-status"] = true,
}

local _M = {}

function _M.execute(conf, version, client)
  -- Only the original request (the one that won the NX lock in the access
  -- phase) persists the response. Duplicates are served from the cache in the
  -- access phase and passthrough requests never reach here.
  if not kong.ctx.plugin.store then
    return
  end

  kong.response.set_header(STATUS_HEADER, "completed")

  if not client then
    kong.log.err("idempotency: no Redis connection; response not cached")
    return
  end

  local idempotency_key = kong.request.get_header(KEY_HEADER)
  local consumer = kong.client.get_consumer()
  local req = {
    host = kong.request.get_host(),
    path = kong.request.get_path(),
    method = kong.request.get_method(),
    consumer = consumer and consumer.id or nil,
  }

  local headers = kong.response.get_headers()
  for name in pairs(VOLATILE_HEADERS) do
    headers[name] = nil
  end

  local payload = {
    headers = headers,
    status = kong.service.response.get_status(),
    body = kong.service.response.get_raw_body(),
  }

  local response_key = keys.response_key(conf, req, idempotency_key)

  local ok, err = client:set(response_key, cjson.encode(payload), "EX", conf.redis_cache_time)
  if ok then
    -- Tell the log phase the response was persisted, so it keeps the lock.
    kong.ctx.plugin.cached = true
  else
    kong.log.err("idempotency: failed to cache response in Redis: ", err)
  end

  cache.release(client)
end

return _M
