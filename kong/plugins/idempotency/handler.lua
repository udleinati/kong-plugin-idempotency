local access = require "kong.plugins.idempotency.access"
local response = require "kong.plugins.idempotency.response"
local cache = require "kong.plugins.idempotency.cache"
local lifecycle = require "kong.plugins.idempotency.lifecycle"

local kong = kong
local ngx = ngx

local Idempotency = {
  VERSION = "2.0.0",
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
  -- Only the Original request writes to the cache; skip the Redis round-trip
  -- entirely for duplicates and passthrough requests.
  if not lifecycle.is_original(kong.ctx.plugin) then
    return
  end

  local client = cache.connection(conf)
  response.execute(conf, Idempotency.VERSION, client)
end

function Idempotency:log(conf)
  -- The Original acquired the lock but never cached a response (e.g. the upstream
  -- failed mid-flight): free the orphaned lock so retries are not stuck on 409
  -- for the whole TTL window. The lifecycle module owns that decision; a nil
  -- result means there is nothing to free (duplicate, passthrough, or a
  -- successful request that keeps its lock to route future duplicates).
  local lock_key = lifecycle.orphaned_lock(kong.ctx.plugin)
  if not lock_key then
    return
  end

  -- Cosocket (Redis) APIs are disabled in the log phase, so defer the delete to
  -- a zero-delay timer, which runs in a context where connections are allowed.
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
