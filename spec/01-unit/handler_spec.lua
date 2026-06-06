local mocks = require "spec.01-unit.support.mocks"

-- Build the handler with fake access/response/cache modules so we can assert on
-- how it wires them together.
local function build(opts)
  opts = opts or {}
  local calls = { access = {}, response = {}, connection = 0 }

  local fake_access = {
    execute = function(conf, version, client)
      calls.access[#calls.access + 1] = { conf = conf, version = version, client = client }
    end,
  }
  local fake_response = {
    execute = function(conf, version, client)
      calls.response[#calls.response + 1] = { conf = conf, version = version, client = client }
    end,
  }
  local fake_cache = {
    connection = function()
      calls.connection = calls.connection + 1
      return "redis-client"
    end,
  }

  local kong_mock = { ctx = { plugin = opts.plugin_ctx or {} } }

  local handler = mocks.load_with("kong.plugins.idempotency.handler", {
    kong = kong_mock,
    ngx = mocks.fake_ngx(),
    packages = {
      ["kong.plugins.idempotency.access"] = fake_access,
      ["kong.plugins.idempotency.response"] = fake_response,
      ["kong.plugins.idempotency.cache"] = fake_cache,
    },
  })

  return handler, calls, kong_mock
end

describe("idempotency handler", function()
  it("runs after authentication (priority -1)", function()
    local handler = build()
    assert.equal(-1, handler.PRIORITY)
  end)

  it("reports a version that matches the rockspec", function()
    local handler = build()
    assert.equal("1.2.0", handler.VERSION)
  end)

  it("opens a connection and delegates :access() with conf, version, client", function()
    local handler, calls = build()
    local conf = { redis = {} }
    handler:access(conf)

    assert.equal(1, calls.connection)
    assert.equal(1, #calls.access)
    assert.equal(conf, calls.access[1].conf)
    assert.equal(handler.VERSION, calls.access[1].version)
    assert.equal("redis-client", calls.access[1].client)
  end)

  it("skips the response phase entirely when this request did not win the lock", function()
    local handler, calls = build({ plugin_ctx = {} })
    handler:response({ redis = {} })

    assert.equal(0, calls.connection)
    assert.equal(0, #calls.response)
  end)

  it("runs the response phase only for the original (lock-winning) request", function()
    local handler, calls = build({ plugin_ctx = { store = true } })
    local conf = { redis = {} }
    handler:response(conf)

    assert.equal(1, calls.connection)
    assert.equal(1, #calls.response)
    assert.equal(conf, calls.response[1].conf)
    assert.equal("redis-client", calls.response[1].client)
  end)
end)
