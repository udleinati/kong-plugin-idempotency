local redis = require "resty.redis"
local kong  = kong

local _M = {}

-- Keepalive settings (same values used by Kong's bundled rate-limiting plugin)
local KEEPALIVE_TIMEOUT   = 10000 -- ms an idle connection stays in the pool
local KEEPALIVE_POOL_SIZE = 100   -- idle connections kept per pool, per worker

function _M.connection(conf)
  -- Create new redis client (pool will recycle connections)
  local red = redis:new()
  red:set_timeout(conf.redis_timeout or 1000) -- default 1s timeout

  -- Dedicated pool per host/port/db/user/ssl: AUTH and SELECT only run on
  -- fresh connections, so a pooled connection must never be shared with a
  -- different database/user (e.g. another plugin using the default host:port pool)
  local pool = string.format(
    "idempotency:%s:%s:%s:%s:%s",
    conf.redis_host,
    conf.redis_port,
    conf.redis_database or "",
    conf.redis_username or "",
    conf.redis_ssl and "ssl" or "plain"
  )

  -- Connect (optionally with TLS)
  local ok, err = red:connect(conf.redis_host, conf.redis_port, {
    ssl         = conf.redis_ssl or false,
    ssl_verify  = conf.redis_ssl_verify or false,
    server_name = conf.redis_server_name,
    pool        = pool,
  })

  if not ok then
    kong.log.err("Redis connect failed: ", err)
    return nil, err
  end

  local times, err = red:get_reused_times()
  if err then
    kong.log.err("Redis get_reused_times failed: ", err)
    return nil, err
  end

  -- Reused connection from the pool is already authenticated and selected
  if times > 0 then
    return red
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

  -- Return redis client (caller must call release after usage)
  return red
end

-- Put the connection back into the pool instead of letting it be closed
-- at the end of the request
function _M.release(red)
  if not red then
    return
  end

  local ok, err = red:set_keepalive(KEEPALIVE_TIMEOUT, KEEPALIVE_POOL_SIZE)
  if not ok then
    kong.log.warn("Redis set_keepalive failed: ", err)
  end
end

return _M
