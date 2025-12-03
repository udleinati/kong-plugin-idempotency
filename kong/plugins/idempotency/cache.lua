local kong = kong
local redis = require 'redis'
local _M = {
  client = nil,
  last_ping_time = 0
}

function ping()
  return _M.client:ping()
end

function _M.connection(conf)
  if _M.client and _M.last_ping_time + 5 > os.time() then
    return _M.client
  end

  if _M.client then
    local result = pcall(ping)

    if result then
      _M.last_ping_time = os.time()
      return _M.client
    end
  end

  local client = redis.connect(conf.redis_host, conf.redis_port)
  _M.client = client

  return _M.client
end

return _M
