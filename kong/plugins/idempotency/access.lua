local cjson = require "cjson"
local cache = require "kong.plugins.idempotency.cache"
local keys = require "kong.plugins.idempotency.keys"

local kong = kong
local null = ngx.null
local md5 = ngx.md5

local KEY_HEADER = "X-Idempotency-Key"
local STATUS_HEADER = "X-Idempotency-Status"

local _M = {}

local function method_enabled(conf, method)
  local methods = conf.methods
  if not methods then
    return method == "POST"
  end
  for i = 1, #methods do
    if methods[i] == method then
      return true
    end
  end
  return false
end

-- True when this request should take part in the idempotency flow at all.
local function should_handle(conf, method, idempotency_key)
  if not method_enabled(conf, method) then
    return false
  end

  -- When the key is optional, only requests that actually carry one are
  -- treated as idempotent.
  if not conf.is_required and not idempotency_key then
    return false
  end

  return true
end

-- Fingerprint of the parts of the request not already in the key scope (which
-- covers consumer/host/path/method): the raw body and the query string.
local function fingerprint(conf)
  if not conf.verify_fingerprint then
    return "1"
  end

  local body = kong.request.get_raw_body()
  if body == nil then
    -- Large bodies are spooled to disk and not returned here; fall back to the
    -- query only (documented limitation).
    kong.log.warn("idempotency: request body unavailable for fingerprint (too large?)")
    body = ""
  end

  return md5(body .. "\0" .. (kong.request.get_raw_query() or ""))
end

-- Reject when the idempotency store is unavailable and fail_open is off.
local function store_unavailable(conf)
  if conf.fail_open then
    return false
  end
  kong.response.exit(503, { message = "Idempotency store unavailable" })
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

  -- Redis unreachable: fail open (proxy normally) or, in strict mode, reject.
  if not client then
    if not conf.fail_open then
      return kong.response.exit(503, { message = "Idempotency store unavailable" })
    end
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
  local fp = fingerprint(conf)

  -- Atomically claim the key: SET key <fingerprint> NX EX <ttl>.
  -- "OK"  -> we won the race and own this request.
  -- null  -> the key already exists (a duplicate).
  local ok, err = client:set(lock_key, fp, "EX", conf.redis_cache_time, "NX")
  if err then
    kong.log.err("idempotency: Redis SET NX failed: ", err)
    cache.release(client)
    if store_unavailable(conf) then return end
    return
  end

  if ok == "OK" then
    -- First request for this key: let it through and mark it so the response
    -- phase persists the upstream response for future duplicates. Remember the
    -- lock so the log phase can release it if this request never caches a
    -- response (e.g. the upstream fails).
    kong.ctx.plugin.store = true
    kong.ctx.plugin.lock_key = lock_key
    cache.release(client)
    return
  end

  -- Duplicate. When fingerprinting is on, reject a reused key whose request
  -- differs from the original (before bothering to read the cached response).
  if conf.verify_fingerprint then
    local stored_fp, lerr = client:get(lock_key)
    if lerr then
      kong.log.err("idempotency: Redis GET (lock) failed: ", lerr)
      cache.release(client)
      if store_unavailable(conf) then return end
      return
    end
    if stored_fp ~= null and stored_fp ~= fp then
      cache.release(client)
      kong.response.set_header(STATUS_HEADER, "conflict")
      return kong.response.exit(422, { message = KEY_HEADER .. " was already used with a different request" })
    end
  end

  -- Replay the cached response if the original already finished.
  local response_key = keys.response_key(conf, req, idempotency_key)
  local cached, gerr = client:get(response_key)
  cache.release(client)

  if gerr then
    kong.log.err("idempotency: Redis GET failed: ", gerr)
    if store_unavailable(conf) then return end
  end

  -- resty.redis returns ngx.null when the key does not exist yet, which means
  -- the original request is still in flight.
  if not cached or cached == null then
    kong.response.set_header(STATUS_HEADER, "waiting_response")
    return kong.response.exit(409, { message = "Idempotent request already in progress" })
  end

  -- Replay the original response verbatim. Guard the decode: a corrupt or
  -- foreign value at the response key must never crash the request.
  local decoded, payload = pcall(cjson.decode, cached)
  if not decoded or type(payload) ~= "table" or not payload.status then
    kong.log.err("idempotency: cached response is unreadable; treating as in-progress")
    kong.response.set_header(STATUS_HEADER, "waiting_response")
    return kong.response.exit(409, { message = "Idempotent request already in progress" })
  end

  for name, value in pairs(payload.headers or {}) do
    kong.response.set_header(name, value)
  end
  kong.response.set_header(STATUS_HEADER, "completed")

  return kong.response.exit(payload.status, payload.body)
end

return _M
