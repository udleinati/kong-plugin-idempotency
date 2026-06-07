local keys = require "kong.plugins.idempotency.keys"

local function conf(overrides)
  local c = { redis_prefix = "kong-idempotency-plugin", redis = {} }
  for k, v in pairs(overrides or {}) do c[k] = v end
  return c
end

local function req(overrides)
  local r = { host = "api.test", path = "/orders", method = "POST", consumer = nil }
  for k, v in pairs(overrides or {}) do r[k] = v end
  return r
end

describe("idempotency keys", function()

  describe("prefix()", function()
    it("namespaces by prefix, consumer (anonymous), host, path and method", function()
      assert.equal(
        "kong-idempotency-plugin:anonymous:api.test:/orders:POST",
        keys.prefix(conf(), req())
      )
    end)

    it("scopes by the authenticated consumer when present", function()
      assert.equal(
        "kong-idempotency-plugin:c-123:api.test:/orders:POST",
        keys.prefix(conf(), req({ consumer = "c-123" }))
      )
    end)

    it("isolates different hosts", function()
      assert.not_equal(
        keys.prefix(conf(), req({ host = "a.test" })),
        keys.prefix(conf(), req({ host = "b.test" }))
      )
    end)

    it("isolates different consumers", function()
      assert.not_equal(
        keys.prefix(conf(), req({ consumer = "alice" })),
        keys.prefix(conf(), req({ consumer = "bob" }))
      )
    end)

    it("scopes by redis username when present", function()
      assert.equal(
        "alice::kong-idempotency-plugin:anonymous:api.test:/orders:POST",
        keys.prefix(conf({ redis = { username = "alice" } }), req())
      )
    end)

    it("falls back when host, path or method are missing", function()
      assert.equal(
        "kong-idempotency-plugin:anonymous:no-host:no-path:UNKNOWN",
        keys.prefix(conf(), { })
      )
    end)
  end)

  describe("lock_key()", function()
    it("uses a :lock: discriminator before the idempotency key", function()
      assert.equal(
        "kong-idempotency-plugin:anonymous:api.test:/orders:POST:lock:abc-123",
        keys.lock_key(conf(), req(), "abc-123")
      )
    end)
  end)

  describe("response_key()", function()
    it("uses a :resp: discriminator before the idempotency key", function()
      assert.equal(
        "kong-idempotency-plugin:anonymous:api.test:/orders:POST:resp:abc-123",
        keys.response_key(conf(), req(), "abc-123")
      )
    end)

    it("differs from the lock key for the same request", function()
      assert.not_equal(
        keys.lock_key(conf(), req(), "k"),
        keys.response_key(conf(), req(), "k")
      )
    end)

    it("a lock key never collides with a response key ending in -response", function()
      -- The bug: lock_key("x-response") used to equal response_key("x").
      assert.not_equal(
        keys.lock_key(conf(), req(), "x-response"),
        keys.response_key(conf(), req(), "x")
      )
    end)
  end)
end)
