local mocks = require "spec.01-unit.support.mocks"

-- conf.redis mirrors the shared kong.tools.redis config record.
local function rconf(overrides)
  local r = {
    host = "127.0.0.1",
    port = 6379,
    timeout = 2000,
    database = 0,
    ssl = false,
    ssl_verify = false,
    server_name = nil,
    username = nil,
    password = nil,
  }
  for k, v in pairs(overrides or {}) do r[k] = v end
  return { redis = r }
end

local function build(opts)
  local ngx_mock = mocks.fake_ngx()
  local kong_mock, recorded = mocks.fake_kong({})
  local redis_module, red = mocks.fake_redis_client(opts)

  local cache = mocks.load_with("kong.plugins.idempotency.cache", {
    kong = kong_mock,
    ngx = ngx_mock,
    packages = { ["resty.redis"] = redis_module },
  })

  return { cache = cache, red = red, recorded = recorded, ngx = ngx_mock }
end

describe("idempotency cache (redis connection)", function()

  describe("connection()", function()
    it("returns an error when the host is missing", function()
      local ctx = build()
      local red, err = ctx.cache.connection({ redis = {} })
      assert.is_nil(red)
      assert.is_string(err)
      assert.is_true(#ctx.recorded.logs > 0)
    end)

    it("connects with the configured timeout and ssl options", function()
      local ctx = build()
      ctx.cache.connection(rconf({ ssl = true, ssl_verify = true, server_name = "redis.test" }))

      assert.equal(2000, ctx.red.calls.timeout[1])
      local sock_opts = ctx.red.calls.connect[1].sock_opts
      assert.is_true(sock_opts.ssl)
      assert.is_true(sock_opts.ssl_verify)
      assert.equal("redis.test", sock_opts.server_name)
    end)

    it("uses the default pool when database is 0", function()
      local ctx = build()
      ctx.cache.connection(rconf())
      assert.is_nil(ctx.red.calls.connect[1].sock_opts.pool)
      assert.equal(0, #ctx.red.calls.select)
    end)

    it("uses a scoped pool and selects the database when non-zero", function()
      local ctx = build()
      ctx.cache.connection(rconf({ database = 3 }))
      assert.equal("127.0.0.1:6379;3", ctx.red.calls.connect[1].sock_opts.pool)
      assert.equal(3, ctx.red.calls.select[1])
    end)

    it("authenticates with username + password when both are set", function()
      local ctx = build()
      ctx.cache.connection(rconf({ username = "u", password = "p" }))
      assert.same({ "u", "p" }, ctx.red.calls.auth[1])
    end)

    it("authenticates with password only when no username", function()
      local ctx = build()
      ctx.cache.connection(rconf({ password = "p" }))
      assert.same({ "p" }, ctx.red.calls.auth[1])
    end)

    it("does not authenticate when no password is configured", function()
      local ctx = build()
      ctx.cache.connection(rconf())
      assert.equal(0, #ctx.red.calls.auth)
    end)

    it("skips auth/select on a reused (pooled) connection", function()
      local ctx = build({ reused_times = 1 })
      ctx.cache.connection(rconf({ password = "p", database = 3 }))
      assert.equal(0, #ctx.red.calls.auth)
      assert.equal(0, #ctx.red.calls.select)
    end)

    it("returns the error when the connection fails", function()
      local ctx = build({ connect_fail = true })
      local red, err = ctx.cache.connection(rconf())
      assert.is_nil(red)
      assert.is_string(err)
    end)
  end)

  describe("release()", function()
    it("hands the connection back to the keepalive pool", function()
      local ctx = build()
      ctx.cache.release(ctx.red)
      assert.equal(1, #ctx.red.calls.keepalive)
    end)

    it("is a no-op for a nil connection", function()
      local ctx = build()
      assert.has_no.errors(function() ctx.cache.release(nil) end)
    end)
  end)

  describe("del()", function()
    it("deletes the given key", function()
      local ctx = build()
      ctx.cache.del(ctx.red, "some-lock-key")
      assert.equal("some-lock-key", ctx.red.calls.del[1])
    end)

    it("logs and does not raise when the delete fails", function()
      local ctx = build({ del_err = "boom" })
      assert.has_no.errors(function() ctx.cache.del(ctx.red, "k") end)
      assert.is_true(#ctx.recorded.logs > 0)
    end)
  end)
end)
