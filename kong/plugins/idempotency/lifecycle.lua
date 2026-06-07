-- The idempotency lifecycle of a single request.
--
-- The access, response and log phases coordinate through a tiny protocol on
-- `kong.ctx.plugin`: whether this request is the Original (won the SET NX lock),
-- whether it cached a response, and which lock key it holds. This module is the
-- single owner of that protocol so the rule "when is a lock freed?" lives in one
-- place instead of being smeared across the three phases.
--
-- Kept free of any `kong`/`ngx` dependency -- the caller passes the ctx table --
-- so the protocol can be unit-tested in isolation (see
-- spec/01-unit/lifecycle_spec.lua), mirroring keys.lua.
--
-- Only the Original ever writes this state; Duplicates and passthrough requests
-- leave it untouched. The `store` field is the Original flag (named for the
-- response-phase behaviour it gates); it stays private to this module.

local _M = {}

-- Mark this request as the Original: it won the lock and is expected to cache a
-- response. Remember the lock key so an orphaned lock can be freed later.
function _M.won_lock(ctx, lock_key)
  ctx.store = true
  ctx.lock_key = lock_key
end

-- True only for the Original request (the one that won the lock). Both the
-- response phase's guard and the handler's connection-skip ask through here.
function _M.is_original(ctx)
  return ctx.store == true
end

-- Record that the Original persisted its response, so the log phase keeps the
-- lock (it is what routes duplicates to the cached response) instead of freeing
-- it.
function _M.cached(ctx)
  ctx.cached = true
end

-- The lock key the log phase must free, or nil. A lock is orphaned when the
-- Original won it but never cached a response (the upstream failed, or a 5xx
-- with cache_5xx off): freeing it stops duplicates from sitting on 409 for the
-- whole TTL.
function _M.orphaned_lock(ctx)
  if not ctx.store or ctx.cached or not ctx.lock_key then
    return nil
  end
  return ctx.lock_key
end

return _M
