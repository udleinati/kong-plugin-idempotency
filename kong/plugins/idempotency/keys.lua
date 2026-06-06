-- Pure helpers that build the Redis keys used by the plugin.
-- Kept free of any `kong`/`ngx` dependency so they can be unit-tested in
-- isolation (see spec/01-unit/keys_spec.lua) and so the access and response
-- phases share a single source of truth for the key format.

local fmt = string.format

local _M = {}

local function is_present(str)
  return str ~= nil and str ~= ""
end

-- Namespaced prefix: "[username::]<redis_prefix>:<path>:<method>".
-- The username scope keeps keys from different ACL users from colliding when
-- they share a Redis instance.
function _M.prefix(conf, method, path)
  local username = conf.redis and conf.redis.username
  local user_scope = is_present(username) and (username .. "::") or ""

  return fmt(
    "%s%s:%s:%s",
    user_scope,
    conf.redis_prefix,
    path or "no-path",
    method or "UNKNOWN"
  )
end

-- The lock key: set with NX while the original request is processed so
-- concurrent duplicates can detect an in-flight request.
function _M.lock_key(conf, method, path, idempotency_key)
  return fmt("%s:%s", _M.prefix(conf, method, path), idempotency_key)
end

-- The response key: holds the JSON-encoded response replayed to duplicates.
function _M.response_key(conf, method, path, idempotency_key)
  return fmt("%s:%s-response", _M.prefix(conf, method, path), idempotency_key)
end

return _M
