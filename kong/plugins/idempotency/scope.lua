-- Builds the request scope an idempotency key is namespaced within:
--   { host, path, method, consumer }
-- This is the kong-coupled half of the key machinery; keys.lua is the pure half
-- that formats this descriptor into Redis keys and is deliberately kept free of
-- the PDK. Centralising the build here keeps the access and response phases from
-- each reconstructing it (and silently drifting apart).
--
-- `kong` is resolved as a global at call time (not captured into an upvalue): as
-- a shared dependency this module is loaded once and reused, so it must read the
-- live PDK rather than a stale reference -- both in production and under the
-- spec harness, which swaps kong.ctx/request per test.

local _M = {}

function _M.from_request()
  local consumer = kong.client.get_consumer()
  return {
    host = kong.request.get_host(),
    path = kong.request.get_path(),
    method = kong.request.get_method(),
    consumer = consumer and consumer.id or nil,
  }
end

return _M
