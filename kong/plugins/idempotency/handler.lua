local access = require "kong.plugins.idempotency.access"
local response = require "kong.plugins.idempotency.response"
local cache = require "kong.plugins.idempotency.cache"

local kong = kong

local Idempotency = {
  VERSION = "1.2.0",
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

return Idempotency
