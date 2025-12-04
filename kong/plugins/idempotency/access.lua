local json = require "cjson"
local kong = kong
local _M = {}

function _M.execute(conf, version, client)
  local method = kong.request.get_method()
  local path = kong.request.get_path()

  local idempotency_key = kong.request.get_header('X-Idempotency-Key')

  if not (method == 'POST') or (not conf.is_required and not idempotency_key) then
    return
  end

  if not idempotency_key then
    kong.response.exit(400, { message = 'X-Idempotency-Key required' })
  end


  -- Build Redis key prefix (response will append -response later)
  local user_prefix = ""

  if conf.redis_username and conf.redis_username ~= "" then
    user_prefix = conf.redis_username .. "::"
  end

  local prefix_redis_key = string.format(
    "%s%s:%s:%s",
    user_prefix,
    conf.redis_prefix,
    path or "no-path",
    method or "UNKNOWN"
  )

  local idem_key = string.format("%s:%s", prefix_redis_key, idempotency_key)

  -------------------------------------------------------------
  -- 1. SET key = true NX EX <ttl>
  -- resty.redis syntax:
  -- client:set(key, value, "EX", ttl, "NX")
  -------------------------------------------------------------
  local ok, err = client:set(idem_key, true, "EX", conf.redis_cache_time, "NX")

  if err then
    kong.log.err("Redis SET NX failed: ", err)
    return
  end

  -- If ok == OK -> first request -> wait until response.lua stores full response
  if ok == "OK" then
    kong.response.set_header("X-Idempotency-Status", "waiting_response")
    return
  end

  -------------------------------------------------------------
  -- 2. Key already exists -> fetch cached response
  -------------------------------------------------------------
  local response_key = string.format("%s:%s-response", prefix_redis_key, idempotency_key)
  local cache, err = client:get(response_key)

  if err then
    kong.log.err("Redis GET failed: ", err)
  end

  -- resty.redis returns ngx.null if key doesn't exist
  if cache == ngx.null or not cache then
    kong.response.set_header("X-Idempotency-Status", "waiting_response")
    kong.response.exit(409, { message = "X-Idempotency-Status waiting_response" })
    return
  end

  -------------------------------------------------------------
  -- 3. Decode cached payload
  -------------------------------------------------------------
  local response = json.decode(cache)

  -- restore headers from the original response
  for name, value in pairs(response.headers or {}) do
    kong.response.set_header(name, value)
  end

  kong.response.set_header('X-Idempotency-Status', 'completed')

  -- restore status and body from the original response
  kong.response.exit(response.status, response.body)
end

return _M
