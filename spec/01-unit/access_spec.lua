local mocks = require "spec.01-unit.support.mocks"
local cjson = require "cjson"

local VERSION = "1.2.0"

local function conf(overrides)
  local c = {
    is_required = false,
    redis_cache_time = 86400,
    redis_prefix = "kong-idempotency-plugin",
    redis = {},
  }
  for k, v in pairs(overrides or {}) do c[k] = v end
  return c
end

-- Build a fully-mocked access module plus handles to assert against.
-- opts.request -> { method, path, headers }
-- opts.redis   -> fake redis replies; the string "NULL" is mapped to ngx.null
-- opts.no_client -> pass nil as the client (simulates a Redis outage)
local function build(opts)
  opts = opts or {}
  local ngx_mock = mocks.fake_ngx()
  local kong_mock, recorded, plugin_ctx = mocks.fake_kong({
    request = opts.request,
    plugin_ctx = opts.plugin_ctx,
  })

  local redis_opts = {}
  for k, v in pairs(opts.redis or {}) do
    redis_opts[k] = (v == "NULL") and ngx_mock.null or v
  end
  local _, red = mocks.fake_redis_client(redis_opts)

  local fake_cache, cache_calls = mocks.fake_cache(red)

  local access = mocks.load_with("kong.plugins.idempotency.access", {
    kong = kong_mock,
    ngx = ngx_mock,
    packages = {
      ["kong.plugins.idempotency.cache"] = fake_cache,
    },
  })

  return {
    access = access,
    red = red,
    recorded = recorded,
    plugin_ctx = plugin_ctx,
    cache_calls = cache_calls,
    ngx = ngx_mock,
    client = (not opts.no_client) and red or nil,
  }
end

local POST = { method = "POST", path = "/orders", host = "api.test", headers = { ["X-Idempotency-Key"] = "k1" } }

describe("idempotency access", function()

  describe("skip conditions", function()
    it("ignores non-POST requests", function()
      local ctx = build({ request = { method = "GET", headers = { ["X-Idempotency-Key"] = "k1" } } })
      ctx.access.execute(conf(), VERSION, ctx.client)

      assert.equal(0, #ctx.red.calls.set)
      assert.is_nil(ctx.recorded.exit)
    end)

    it("ignores POST without a key when the key is optional", function()
      local ctx = build({ request = { method = "POST", path = "/orders", headers = {} } })
      ctx.access.execute(conf({ is_required = false }), VERSION, ctx.client)

      assert.equal(0, #ctx.red.calls.set)
      assert.is_nil(ctx.recorded.exit)
    end)

    it("treats an empty key header as no key (no shared cache entry)", function()
      local ctx = build({ request = { method = "POST", path = "/orders", headers = { ["X-Idempotency-Key"] = "" } } })
      ctx.access.execute(conf({ is_required = false }), VERSION, ctx.client)

      assert.equal(0, #ctx.red.calls.set, "an empty key must not claim a redis lock")
      assert.is_nil(ctx.recorded.exit)
    end)
  end)

  describe("required key", function()
    it("rejects POST without a key with 400", function()
      local ctx = build({ request = { method = "POST", path = "/orders", headers = {} } })
      ctx.access.execute(conf({ is_required = true }), VERSION, ctx.client)

      assert.equal(400, ctx.recorded.exit.status)
      assert.equal(0, #ctx.red.calls.set)
    end)

    it("rejects POST with an empty key with 400", function()
      local ctx = build({ request = { method = "POST", path = "/orders", headers = { ["X-Idempotency-Key"] = "" } } })
      ctx.access.execute(conf({ is_required = true }), VERSION, ctx.client)

      assert.equal(400, ctx.recorded.exit.status)
      assert.equal(0, #ctx.red.calls.set)
    end)
  end)

  describe("redis outage", function()
    it("fails open (passes through) when there is no connection", function()
      local ctx = build({ request = POST, no_client = true })
      ctx.access.execute(conf(), VERSION, nil)

      assert.is_nil(ctx.recorded.exit)
      assert.is_true(#ctx.recorded.logs > 0)
    end)
  end)

  describe("first request (lock acquired)", function()
    it("claims the lock with NX/EX, marks ctx.store and releases the connection", function()
      local ctx = build({ request = POST, redis = { set_return = "OK" } })
      ctx.access.execute(conf({ redis_cache_time = 120 }), VERSION, ctx.client)

      local set = ctx.red.calls.set[1]
      assert.equal("kong-idempotency-plugin:anonymous:api.test:/orders:POST:lock:k1", set.key)
      assert.equal("1", set.value)
      assert.same({ "EX", 120, "NX" }, set.args)

      assert.is_true(ctx.plugin_ctx.store)
      -- the lock key is remembered for the log-phase cleanup
      assert.equal(set.key, ctx.plugin_ctx.lock_key)
      assert.is_nil(ctx.recorded.exit)
      assert.equal(1, #ctx.cache_calls.release)
    end)

    it("scopes the lock key by the authenticated consumer", function()
      local request = { method = "POST", path = "/orders", host = "api.test",
                        consumer = { id = "c-1" }, headers = { ["X-Idempotency-Key"] = "k1" } }
      local ctx = build({ request = request, redis = { set_return = "OK" } })
      ctx.access.execute(conf(), VERSION, ctx.client)

      assert.equal("kong-idempotency-plugin:c-1:api.test:/orders:POST:lock:k1", ctx.red.calls.set[1].key)
    end)
  end)

  describe("duplicate request (lock already held)", function()
    it("returns 409 while the original is still in flight (no cached response)", function()
      local ctx = build({ request = POST, redis = { set_return = "NULL", get_return = "NULL" } })
      ctx.access.execute(conf(), VERSION, ctx.client)

      assert.equal(409, ctx.recorded.exit.status)
      assert.equal("waiting_response", ctx.recorded.response_headers["X-Idempotency-Status"])
      assert.is_false(ctx.plugin_ctx.store == true)
      assert.equal(1, #ctx.cache_calls.release)
    end)

    it("replays the cached response when the original has finished", function()
      local cached = cjson.encode({
        status = 201,
        body = "created",
        headers = { ["x-resource-id"] = "42" },
      })
      local ctx = build({ request = POST, redis = { set_return = "NULL", get_return = cached } })
      ctx.access.execute(conf(), VERSION, ctx.client)

      assert.equal(201, ctx.recorded.exit.status)
      assert.equal("created", ctx.recorded.exit.body)
      assert.equal("42", ctx.recorded.response_headers["x-resource-id"])
      assert.equal("completed", ctx.recorded.response_headers["X-Idempotency-Status"])
      assert.equal("kong-idempotency-plugin:anonymous:api.test:/orders:POST:resp:k1", ctx.red.calls.get[1])
      assert.equal(1, #ctx.cache_calls.release)
    end)

    it("does not crash on a corrupt/non-object cached value; returns 409", function()
      -- e.g. a foreign value at the response key decodes to a number.
      local ctx = build({ request = POST, redis = { set_return = "NULL", get_return = "1" } })
      assert.has_no.errors(function()
        ctx.access.execute(conf(), VERSION, ctx.client)
      end)
      assert.equal(409, ctx.recorded.exit.status)
      assert.equal("waiting_response", ctx.recorded.response_headers["X-Idempotency-Status"])
    end)
  end)

  describe("redis errors", function()
    it("fails open when the SET command errors", function()
      local ctx = build({ request = POST, redis = { set_err = "timeout" } })
      ctx.access.execute(conf(), VERSION, ctx.client)

      assert.is_nil(ctx.recorded.exit)
      assert.is_false(ctx.plugin_ctx.store == true)
      assert.is_true(#ctx.recorded.logs > 0)
    end)
  end)
end)
