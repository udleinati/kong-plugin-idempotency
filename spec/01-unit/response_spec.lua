local mocks = require "spec.01-unit.support.mocks"
local cjson = require "cjson"

local VERSION = "1.2.0"

local function conf(overrides)
  local c = {
    redis_cache_time = 86400,
    redis_prefix = "kong-idempotency-plugin",
    redis = {},
  }
  for k, v in pairs(overrides or {}) do c[k] = v end
  return c
end

local function build(opts)
  opts = opts or {}
  local ngx_mock = mocks.fake_ngx()
  local kong_mock, recorded, plugin_ctx = mocks.fake_kong({
    request = opts.request or { method = "POST", path = "/orders", headers = { ["X-Idempotency-Key"] = "k1" } },
    response = opts.response,
    plugin_ctx = opts.plugin_ctx or { store = true },
  })

  local _, red = mocks.fake_redis_client(opts.redis or {})
  local fake_cache, cache_calls = mocks.fake_cache(red)

  local response = mocks.load_with("kong.plugins.idempotency.response", {
    kong = kong_mock,
    ngx = ngx_mock,
    packages = {
      ["kong.plugins.idempotency.cache"] = fake_cache,
    },
  })

  return {
    response = response,
    red = red,
    recorded = recorded,
    plugin_ctx = plugin_ctx,
    cache_calls = cache_calls,
    client = (not opts.no_client) and red or nil,
  }
end

describe("idempotency response", function()

  it("does nothing unless this request won the lock (ctx.store)", function()
    local ctx = build({ plugin_ctx = {} })
    ctx.response.execute(conf(), VERSION, ctx.client)

    assert.equal(0, #ctx.red.calls.set)
    assert.is_nil(ctx.recorded.response_headers["X-Idempotency-Status"])
  end)

  it("caches the upstream response under the response key with the TTL", function()
    local ctx = build({
      response = { status = 201, body = "created", headers = { ["x-resource-id"] = "42" } },
      redis = { set_return = "OK" },
    })
    ctx.response.execute(conf({ redis_cache_time = 120 }), VERSION, ctx.client)

    local set = ctx.red.calls.set[1]
    assert.equal("kong-idempotency-plugin:/orders:POST:k1-response", set.key)
    assert.same({ "EX", 120 }, set.args)

    local payload = cjson.decode(set.value)
    assert.equal(201, payload.status)
    assert.equal("created", payload.body)
    assert.equal("42", payload.headers["x-resource-id"])

    assert.equal("completed", ctx.recorded.response_headers["X-Idempotency-Status"])
    assert.equal(1, #ctx.cache_calls.release)
  end)

  it("strips hop-by-hop and length headers before caching", function()
    local ctx = build({
      response = {
        status = 200,
        body = "ok",
        headers = {
          ["content-type"] = "application/json",
          ["connection"] = "keep-alive",
          ["content-length"] = "2",
          ["transfer-encoding"] = "chunked",
          ["x-idempotency-status"] = "completed",
        },
      },
    })
    ctx.response.execute(conf(), VERSION, ctx.client)

    local payload = cjson.decode(ctx.red.calls.set[1].value)
    assert.equal("application/json", payload.headers["content-type"])
    assert.is_nil(payload.headers["connection"])
    assert.is_nil(payload.headers["content-length"])
    assert.is_nil(payload.headers["transfer-encoding"])
    assert.is_nil(payload.headers["x-idempotency-status"])
  end)

  it("still marks the response completed when Redis is unreachable", function()
    local ctx = build({ no_client = true })
    ctx.response.execute(conf(), VERSION, nil)

    assert.equal("completed", ctx.recorded.response_headers["X-Idempotency-Status"])
    assert.is_true(#ctx.recorded.logs > 0)
  end)
end)
