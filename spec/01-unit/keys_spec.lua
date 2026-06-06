local keys = require "kong.plugins.idempotency.keys"

local function conf(overrides)
  local c = { redis_prefix = "kong-idempotency-plugin", redis = {} }
  for k, v in pairs(overrides or {}) do c[k] = v end
  return c
end

describe("idempotency keys", function()

  describe("prefix()", function()
    it("namespaces by prefix, path and method", function()
      assert.equal(
        "kong-idempotency-plugin:/orders:POST",
        keys.prefix(conf(), "POST", "/orders")
      )
    end)

    it("scopes by redis username when present", function()
      assert.equal(
        "alice::kong-idempotency-plugin:/orders:POST",
        keys.prefix(conf({ redis = { username = "alice" } }), "POST", "/orders")
      )
    end)

    it("does not scope when the username is empty", function()
      assert.equal(
        "kong-idempotency-plugin:/orders:POST",
        keys.prefix(conf({ redis = { username = "" } }), "POST", "/orders")
      )
    end)

    it("falls back when path or method are missing", function()
      assert.equal(
        "kong-idempotency-plugin:no-path:UNKNOWN",
        keys.prefix(conf(), nil, nil)
      )
    end)
  end)

  describe("lock_key()", function()
    it("appends the idempotency key to the prefix", function()
      assert.equal(
        "kong-idempotency-plugin:/orders:POST:abc-123",
        keys.lock_key(conf(), "POST", "/orders", "abc-123")
      )
    end)
  end)

  describe("response_key()", function()
    it("appends the idempotency key with a -response suffix", function()
      assert.equal(
        "kong-idempotency-plugin:/orders:POST:abc-123-response",
        keys.response_key(conf(), "POST", "/orders", "abc-123")
      )
    end)

    it("differs from the lock key for the same request", function()
      local c = conf()
      assert.not_equal(
        keys.lock_key(c, "POST", "/orders", "k"),
        keys.response_key(c, "POST", "/orders", "k")
      )
    end)
  end)
end)
