local lifecycle = require "kong.plugins.idempotency.lifecycle"

-- The lifecycle module owns the small protocol the access/response/log phases
-- coordinate through on kong.ctx.plugin. It is pure, so these specs drive it
-- with a plain table standing in for kong.ctx.plugin -- no kong/ngx needed.

describe("idempotency lifecycle", function()

  describe("is_original()", function()
    it("is false for a fresh request (a duplicate or passthrough)", function()
      -- Nothing claimed the lock, so the response phase must not cache and the
      -- log phase must not free anything.
      assert.is_false(lifecycle.is_original({}))
    end)

    it("is true once this request has won the lock", function()
      local ctx = {}
      lifecycle.won_lock(ctx, "the-lock")
      assert.is_true(lifecycle.is_original(ctx))
    end)
  end)

  describe("won_lock()", function()
    it("remembers the lock key so the log phase can free an orphan", function()
      local ctx = {}
      lifecycle.won_lock(ctx, "scope:lock:k1")
      -- Without a cached response, that remembered key is exactly what gets freed.
      assert.equal("scope:lock:k1", lifecycle.orphaned_lock(ctx))
    end)
  end)

  describe("orphaned_lock()", function()
    it("returns nil when this request never won the lock", function()
      -- A duplicate/passthrough holds no lock, so there is nothing to free.
      assert.is_nil(lifecycle.orphaned_lock({ cached = true, lock_key = "x" }))
    end)

    it("returns the lock key for an Original that never cached a response", function()
      -- Upstream failed (or a 5xx with cache_5xx off): the lock is orphaned and
      -- must be freed or duplicates sit on 409 for the whole TTL.
      local ctx = {}
      lifecycle.won_lock(ctx, "orphaned-lock")
      assert.equal("orphaned-lock", lifecycle.orphaned_lock(ctx))
    end)

    it("returns nil once the Original has cached its response", function()
      -- A cached response means the lock is load-bearing -- it routes duplicates
      -- to the cache -- so it must be kept, not freed.
      local ctx = {}
      lifecycle.won_lock(ctx, "kept-lock")
      lifecycle.cached(ctx)
      assert.is_nil(lifecycle.orphaned_lock(ctx))
    end)

    it("returns nil for an Original with no remembered lock key", function()
      -- Defensive: never schedule a delete without a concrete key to delete.
      assert.is_nil(lifecycle.orphaned_lock({ store = true }))
    end)
  end)
end)
