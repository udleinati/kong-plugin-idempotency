local json = require "cjson"
local kong = kong
local _M = {}

function _M.execute(conf, version, client)
  local method = kong.request.get_method()
  local path = kong.request.get_path()
  local idempotency_key = kong.request.get_header('X-Idempotency-Key')

  -- Only POST should be idempotent
  if not (method == 'POST') or (not conf.is_required and not idempotency_key) then
    return
  end

  kong.response.set_header('X-Idempotency-Status', 'completed')

  -- Build the Redis key prefix
  local user_prefix = ""

  if conf.redis_username and conf.redis_username ~= "" then
    user_prefix = conf.redis_username .. "::"
  end

  local prefix_redis_key = string.format(
    "%s%s:%s:%s",
    user_prefix,
    conf.redis_prefix,
    path or "no-path",
    method or "UNKNOWN",
    idempotency_key
  )

  -- Cache payload
  local payload = {
    headers = kong.response.get_headers(),
    status = kong.service.response.get_status(),
    body = kong.service.response.get_raw_body()
  }

  payload.headers["connection"] = nil
  payload.headers["X-Idempotency-Status"] = nil

  local redis_key = string.format("%s:%s-response", prefix_redis_key, idempotency_key)

  -- resty.redis syntax for SET with EX and NX:
  -- client:set(key, value, "EX", ttl)
  local ok, err = client:set(redis_key, json.encode(payload), "EX", conf.redis_cache_time)

  if not ok then
    kong.log.err("Failed to write idempotency cache to Redis: ", err)
  end
end

return _M
