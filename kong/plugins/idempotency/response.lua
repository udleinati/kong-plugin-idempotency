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

  kong.response.set_header('x-idempotency-status', 'completed')

  local prefix_redis_key = string.format(
    "%s:%s:%s",
    prefix,
    path or "no-path",
    method or "UNKNOWN",
    idempotency_key
  )

  local payload = {
    headers = kong.response.get_headers(),
    status = kong.service.response.get_status(),
    body = kong.service.response.get_raw_body()
  }

  payload.headers["connection"] = nil
  payload.headers["x-idempotency-status"] = nil

  client:set(string.format('%s:%s-response', prefix_redis_key, idempotency_key), json.encode(payload), 'ex', conf.redis_cache_time)
end

return _M
