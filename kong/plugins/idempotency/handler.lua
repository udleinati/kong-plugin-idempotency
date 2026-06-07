local access = require "kong.plugins.idempotency.access"
local response = require "kong.plugins.idempotency.response"
local cache = require "kong.plugins.idempotency.cache"

local kong = kong
local ngx = ngx

local Idempotency = {
  VERSION = "1.3.0",
  -- Low priority so the plugin runs after authentication: idempotency keys are
  -- namespaced per ACL user (see keys.lua) and the cached response belongs to
  -- the authenticated caller.
  PRIORITY = -1,
}

function Idempotency:access(conf)
  local client = cache.connection(conf)
  access.execute(conf, Idempotency.VERSION, client)
end

function Idempotency:response(conf)
  -- Only the original request writes to the cache; skip the Redis round-trip
  -- entirely for duplicates and passthrough requests.
  if not kong.ctx.plugin.store then
    return
  end

  local client = cache.connection(conf)
  response.execute(conf, Idempotency.VERSION, client)
end

function Idempotency:log(conf)
  local ctx = kong.ctx.plugin

  -- The original request acquired the lock but never cached a response (e.g. the
  -- upstream failed mid-flight). Release the lock so retries are not stuck on 409
  -- for the whole TTL window. Successful requests keep their lock (it is what
  -- routes duplicates to the cached response) and schedule no cleanup.
  if not ctx.store or ctx.cached or not ctx.lock_key then
    return
  end

  -- Cosocket (Redis) APIs are disabled in the log phase, so defer the delete to
  -- a zero-delay timer, which runs in a context where connections are allowed.
  local lock_key = ctx.lock_key
  local ok, err = ngx.timer.at(0, function(premature)
    if premature then
      return
    end
    local client = cache.connection(conf)
    if not client then
      return
    end
    cache.del(client, lock_key)
    cache.release(client)
  end)

  if not ok then
    kong.log.err("idempotency: failed to schedule lock cleanup: ", err)
  end
end

return Idempotency
