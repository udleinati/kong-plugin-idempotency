-- The cached-response payload: the single owner of what an Original's response
-- looks like in Redis and what counts as a valid one to replay.
--
-- The response phase encodes here (stripping headers that must not be replayed
-- verbatim); the access phase decodes here (rejecting anything corrupt or
-- foreign). Keeping both halves of that contract in one module stops the strip
-- list and the decode guard from drifting apart. Pure (cjson only), so the
-- "what is valid?" rule is unit-tested directly (see spec/01-unit/payload_spec.lua).

local cjson = require "cjson"

-- Hop-by-hop / length headers must not be stored and replayed verbatim: the body
-- is re-sent on replay so Kong recomputes these. Keys are lowercase to match
-- kong.response.get_headers().
local VOLATILE_HEADERS = {
  ["connection"] = true,
  ["content-length"] = true,
  ["transfer-encoding"] = true,
  ["x-idempotency-status"] = true,
}

local _M = {}

-- Encode an Original's response for storage. `response` is { status, body,
-- headers }; the volatile headers are stripped from the (caller-owned) headers
-- table before encoding.
function _M.encode(response)
  local headers = response.headers or {}
  for name in pairs(VOLATILE_HEADERS) do
    headers[name] = nil
  end

  return cjson.encode({
    status = response.status,
    body = response.body,
    headers = headers,
  })
end

-- Decode a stored payload back into a response to replay, or nil if the value is
-- unreadable: not JSON, not an object, or missing a status. A nil result must be
-- treated as "no replayable response" (the original is still in flight, or the
-- key holds a corrupt/foreign value) -- never crash the request over it.
function _M.decode(stored)
  local ok, value = pcall(cjson.decode, stored)
  if not ok or type(value) ~= "table" or not value.status then
    return nil
  end
  return value
end

return _M
