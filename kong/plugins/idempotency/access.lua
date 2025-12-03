local json = require "cjson"
local kong = kong
local _M = {}

function _M.execute(conf, version, prefix, client)
  local method = kong.request.get_method()
  local path = kong.request.get_path()

  local idempotency_key = kong.request.get_header('x-idempotency-key')

  if not (method == 'POST') or (not conf.is_required and not idempotency_key) then
    return
  end

  if not idempotency_key then
    kong.response.exit(400, { message = 'x-idempotency-key required' })
  end


  -- Begin idempotency handling: build Redis key prefix
  local prefix_redis_key = string.format(
    "%s:%s:%s",
    prefix,
    path or "no-path",
    method or "UNKNOWN"
  )

  local inserted_cache = client:set(string.format("%s:%s", prefix_redis_key, idempotency_key), true, 'ex', conf.redis_cache_time, 'nx')

  -- If Redis returned success, this request is the first one.
  -- The response will later be stored by response.lua.
  if inserted_cache then
    kong.response.set_header('x-idempotency-status', 'waiting_response')
    return
  end

  -- If the key already exists, return the response saved in Redis
  local cache = client:get(string.format('%s:%s-response', prefix_redis_key, idempotency_key))

  -- If the response is not yet in Redis, it means the request is occurring in parallel
  if not cache then
    kong.response.set_header('x-idempotency-status', 'waiting_response')
    kong.response.exit(409, { message = 'x-idempotency-status waiting_response' })
    return
  end

  local response = json.decode(cache)

  kong.response.set_header('x-idempotency-status', 'completed')
  kong.response.exit(response.status, response.body)
end

return _M
