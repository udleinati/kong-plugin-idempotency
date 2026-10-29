local access = require "kong.plugins.idempotency.access"
local response = require "kong.plugins.idempotency.response"

local Idempotency = {
  VERSION = "1.1.3",
  PRIORITY = -1
}

function Idempotency:access(conf)
  access.execute(conf, Idempotency.VERSION)
end

function Idempotency:response(conf)
  response.execute(conf, Idempotency.VERSION)
end

return Idempotency
