local redis = require "resty.redis"
local kong  = kong

local _M = {}

function _M.connection(conf)
  -- Create new redis client (pool will recycle connections)
  local red = redis:new()
  red:set_timeout(conf.redis_timeout or 1000) -- default 1s timeout

  -- Connect (optionally with TLS)
  local ok, err = red:connect(conf.redis_host, conf.redis_port, {
    ssl         = conf.redis_ssl or false,
    ssl_verify  = conf.redis_ssl_verify or false,
    server_name = conf.redis_server_name,
  })

  if not ok then
    kong.log.err("Redis connect failed: ", err)
    return nil, err
  end

  -- AUTH support (ACL user or simple password)
  if conf.redis_username and conf.redis_password then
    ok, err = red:auth(conf.redis_username, conf.redis_password)
    if not ok then
      kong.log.err("Redis AUTH (username/password) failed: ", err)
      return nil, err
    end
  elseif conf.redis_password then
    ok, err = red:auth(conf.redis_password)
    if not ok then
      kong.log.err("Redis AUTH (password) failed: ", err)
      return nil, err
    end
  end

  -- SELECT DB (not supported in Redis Cluster)
  if conf.redis_database then
    ok, err = red:select(conf.redis_database)
    if not ok then
      kong.log.err("Redis SELECT failed: ", err)
      return nil, err
    end
  end

  -- Return redis client (caller must set_keepalive after usage)
  return red
end

return _M
