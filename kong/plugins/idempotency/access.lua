local cjson = require "cjson"
local cache = require "kong.plugins.idempotency.cache"
local keys = require "kong.plugins.idempotency.keys"

local kong = kong
local null = ngx.null

local KEY_HEADER = "X-Idempotency-Key"
local STATUS_HEADER = "X-Idempotency-Status"

local _M = {}

-- True when this request should take part in the idempotency flow at all.
local function should_handle(conf, method, idempotency_key)
  if method ~= "POST" then
    return false
  end

  -- When the key is optional, only requests that actually carry one are
  -- treated as idempotent.
  if not conf.is_required and not idempotency_key then
    return false
  end

  return true
end

function _M.execute(conf, version, client)
  local method = kong.request.get_method()
  local idempotency_key = kong.request.get_header(KEY_HEADER)

  -- Treat an empty header value as no key at all. Otherwise every request that
  -- sends `X-Idempotency-Key:` (empty) would share a single cache entry and
  -- leak responses across unrelated requests (empty string is truthy in Lua).
  if idempotency_key == "" then
    idempotency_key = nil
  end

  if not should_handle(conf, method, idempotency_key) then
    return
  end

  -- is_required == true and no key supplied.
  if not idempotency_key then
    return kong.response.exit(400, { message = KEY_HEADER .. " is required" })
  end

  -- Redis unreachable: fail open so an idempotency-cache outage never takes the
  -- protected service down. The request is simply proxied normally.
  if not client then
    kong.log.err("idempotency: no Redis connection; passing request through")
    return
  end

  local consumer = kong.client.get_consumer()
  local req = {
    host = kong.request.get_host(),
    path = kong.request.get_path(),
    method = method,
    consumer = consumer and consumer.id or nil,
  }
  local lock_key = keys.lock_key(conf, req, idempotency_key)

  -- Atomically claim the key: SET key 1 NX EX <ttl>.
  -- "OK"  -> we won the race and own this request.
  -- null  -> the key already exists (a duplicate).
  local ok, err = client:set(lock_key, "1", "EX", conf.redis_cache_time, "NX")
  if err then
    kong.log.err("idempotency: Redis SET NX failed: ", err)
    return
  end

  if ok == "OK" then
    -- First request for this key: let it through and mark it so the response
    -- phase persists the upstream response for future duplicates.
    kong.ctx.plugin.store = true
    cache.release(client)
    return
  end

  -- Duplicate: replay the cached response if the original already finished.
  local response_key = keys.response_key(conf, req, idempotency_key)
  local cached, gerr = client:get(response_key)
  cache.release(client)

  if gerr then
    kong.log.err("idempotency: Redis GET failed: ", gerr)
  end

  -- resty.redis returns ngx.null when the key does not exist yet, which means
  -- the original request is still in flight.
  if not cached or cached == null then
    kong.response.set_header(STATUS_HEADER, "waiting_response")
    return kong.response.exit(409, { message = "Idempotent request already in progress" })
  end

  -- Replay the original response verbatim.
  local payload = cjson.decode(cached)

  for name, value in pairs(payload.headers or {}) do
    kong.response.set_header(name, value)
  end
  kong.response.set_header(STATUS_HEADER, "completed")

  return kong.response.exit(payload.status, payload.body)
end

return _M
