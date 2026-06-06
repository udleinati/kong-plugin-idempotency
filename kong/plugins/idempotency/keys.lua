-- Pure helpers that build the Redis keys used by the plugin.
-- Kept free of any `kong`/`ngx` dependency so they can be unit-tested in
-- isolation (see spec/01-unit/keys_spec.lua) and so the access and response
-- phases share a single source of truth for the key format.

local fmt = string.format

local _M = {}

local function is_present(str)
  return str ~= nil and str ~= ""
end

-- Namespaced scope:
--   "[<redis-username>::]<redis_prefix>:<consumer>:<host>:<path>:<method>"
--
-- The scope deliberately includes the authenticated consumer and the request
-- host on top of path+method, so the same client-supplied idempotency key
-- cannot collide (and leak responses) across different consumers, hosts or
-- endpoints that share one Redis instance. `req` is a table with:
--   { host, path, method, consumer }   (consumer = consumer id or nil)
function _M.prefix(conf, req)
  local username = conf.redis and conf.redis.username
  local user_scope = is_present(username) and (username .. "::") or ""
  local consumer = is_present(req.consumer) and req.consumer or "anonymous"

  return fmt(
    "%s%s:%s:%s:%s:%s",
    user_scope,
    conf.redis_prefix,
    consumer,
    req.host or "no-host",
    req.path or "no-path",
    req.method or "UNKNOWN"
  )
end

-- The lock key: set with NX while the original request is processed so
-- concurrent duplicates can detect an in-flight request.
--
-- The fixed ":lock:" / ":resp:" discriminator sits *before* the free-form
-- idempotency key, so a lock key and a response key can never collide no matter
-- what the key contains (e.g. a key ending in "-response").
function _M.lock_key(conf, req, idempotency_key)
  return fmt("%s:lock:%s", _M.prefix(conf, req), idempotency_key)
end

-- The response key: holds the JSON-encoded response replayed to duplicates.
function _M.response_key(conf, req, idempotency_key)
  return fmt("%s:resp:%s", _M.prefix(conf, req), idempotency_key)
end

return _M
