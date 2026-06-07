-- Redis connection management for the idempotency plugin.
--
-- Reads the shared `conf.redis.*` config record (Kong 3.6+, kong.tools.redis)
-- so it benefits from vault-referenceable credentials, TLS/SNI and per-database
-- connection pooling. Callers MUST hand the connection back with `release`
-- once they are done so it returns to the cosocket keepalive pool.

local redis = require "resty.redis"

local kong = kong
local fmt = string.format

local _M = {}

local function is_present(str)
  return str ~= nil and str ~= "" and str ~= ngx.null
end

-- Open (or reuse, via the pool) a Redis connection. Returns `nil, err` on any
-- failure; the caller is expected to fail open rather than crash the request.
function _M.connection(conf)
  local rconf = conf.redis

  if not rconf or not is_present(rconf.host) then
    kong.log.err("idempotency: missing Redis host configuration")
    return nil, "missing redis host"
  end

  local red = redis:new()
  red:set_timeout(rconf.timeout or 2000)

  -- A per-call local: a module-level table would be shared across concurrent
  -- requests and could be clobbered when routes use different Redis configs.
  local sock_opts = {
    ssl = rconf.ssl,
    ssl_verify = rconf.ssl_verify,
    server_name = rconf.server_name,
  }

  -- Use a dedicated pool only when a non-zero database is selected; otherwise
  -- the default host:port pool is correct and shared.
  if rconf.database and rconf.database ~= 0 then
    sock_opts.pool = fmt("%s:%d;%d", rconf.host, rconf.port, rconf.database)
  end

  local ok, err = red:connect(rconf.host, rconf.port, sock_opts)
  if not ok then
    kong.log.err("idempotency: failed to connect to Redis: ", err)
    return nil, err
  end

  local times, terr = red:get_reused_times()
  if terr then
    kong.log.err("idempotency: failed to get connection reused times: ", terr)
    return nil, terr
  end

  -- Only AUTH/SELECT on a fresh connection; pooled connections already carry
  -- the authenticated, database-selected state.
  if times == 0 then
    if is_present(rconf.password) then
      local aok, aerr
      if is_present(rconf.username) then
        aok, aerr = red:auth(rconf.username, rconf.password)
      else
        aok, aerr = red:auth(rconf.password)
      end
      if not aok then
        kong.log.err("idempotency: failed to authenticate to Redis: ", aerr)
        return nil, aerr
      end
    end

    if rconf.database and rconf.database ~= 0 then
      local sok, serr = red:select(rconf.database)
      if not sok then
        kong.log.err("idempotency: failed to select Redis database: ", serr)
        return nil, serr
      end
    end
  end

  return red
end

-- Delete a key (used to release an orphaned lock when the original request
-- failed to cache a response).
function _M.del(red, key)
  local ok, err = red:del(key)
  if not ok then
    kong.log.err("idempotency: failed to delete key: ", err)
  end
  return ok
end

-- Return the connection to the keepalive pool (10s idle, 100 per worker).
function _M.release(red)
  if not red then
    return
  end

  local ok, err = red:set_keepalive(10000, 100)
  if not ok then
    kong.log.err("idempotency: failed to set Redis keepalive: ", err)
  end
end

return _M
