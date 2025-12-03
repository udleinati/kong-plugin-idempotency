local access = require "kong.plugins.idempotency.access"
local response = require "kong.plugins.idempotency.response"
local cache = require "kong.plugins.idempotency.cache"
local prefix = 'kong-idempotency-plugin'

local Idempotency = {
  VERSION = "0.1.0",
  PRIORITY = -1
}

function Idempotency:access(conf)
  local client = cache.connection(conf)
  access.execute(conf, Idempotency.VERSION, prefix, client)
end

function Idempotency:response(conf)
  local client = cache.connection(conf)
  response.execute(conf, Idempotency.VERSION, prefix, client)
end

return Idempotency
