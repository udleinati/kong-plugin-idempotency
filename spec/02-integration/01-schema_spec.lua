local PLUGIN_NAME = "idempotency"

-- Validate a plugin config against the schema, the way Kong's Admin API does.
local validate
do
  local validate_entity = require("spec.helpers").validate_plugin_config_schema
  local plugin_schema = require("kong.plugins." .. PLUGIN_NAME .. ".schema")

  function validate(config)
    return validate_entity(config, plugin_schema)
  end
end

describe(PLUGIN_NAME .. ": schema", function()
  it("accepts a minimal config with the required redis host", function()
    local ok, err = validate({ redis = { host = "127.0.0.1" } })
    assert.is_nil(err)
    assert.is_truthy(ok)
  end)

  it("requires a redis host", function()
    local ok, err = validate({})
    assert.is_falsy(ok)
    assert.is_not_nil(err)
  end)

  it("applies the documented defaults", function()
    local ok = validate({ redis = { host = "127.0.0.1" } })
    assert.is_false(ok.config.is_required)
    assert.same({ "POST" }, ok.config.methods)
    assert.is_true(ok.config.verify_fingerprint)
    assert.is_false(ok.config.cache_5xx)
    assert.is_true(ok.config.fail_open)
    assert.equal(86400, ok.config.redis_cache_time)
    assert.equal("kong-idempotency-plugin", ok.config.redis_prefix)
    -- defaults from the shared redis schema
    assert.equal(6379, ok.config.redis.port)
    assert.equal(0, ok.config.redis.database)
    assert.is_false(ok.config.redis.ssl)
  end)

  it("accepts a custom methods list", function()
    local ok = validate({ redis = { host = "127.0.0.1" }, methods = { "POST", "PUT", "PATCH", "DELETE" } })
    assert.is_truthy(ok)
    assert.same({ "POST", "PUT", "PATCH", "DELETE" }, ok.config.methods)
  end)

  it("rejects an unsupported method", function()
    local ok, err = validate({ redis = { host = "127.0.0.1" }, methods = { "GET" } })
    assert.is_falsy(ok)
    assert.is_not_nil(err.config.methods)
  end)

  it("rejects an empty methods list", function()
    local ok, err = validate({ redis = { host = "127.0.0.1" }, methods = {} })
    assert.is_falsy(ok)
    assert.is_not_nil(err.config.methods)
  end)

  it("rejects a non-positive redis_cache_time", function()
    local ok, err = validate({ redis = { host = "127.0.0.1" }, redis_cache_time = 0 })
    assert.is_falsy(ok)
    assert.is_not_nil(err.config.redis_cache_time)
  end)

  it("rejects a fractional redis_cache_time (Redis EX needs whole seconds)", function()
    local ok, err = validate({ redis = { host = "127.0.0.1" }, redis_cache_time = 1.5 })
    assert.is_falsy(ok)
    assert.is_not_nil(err.config.redis_cache_time)
  end)

  it("accepts a complete redis config (nested config.redis.*)", function()
    local ok = validate({
      redis = {
        host = "127.0.0.1",
        port = 6380,
        timeout = 1000,
        database = 2,
      },
    })
    assert.is_truthy(ok)
    assert.equal("127.0.0.1", ok.config.redis.host)
    assert.equal(6380, ok.config.redis.port)
    assert.equal(2, ok.config.redis.database)
  end)

  it("still accepts the legacy flat redis_* config and folds it into config.redis", function()
    local ok = validate({
      redis_host = "127.0.0.1",
      redis_port = 6380,
      redis_timeout = 1000,
    })
    assert.is_truthy(ok)
    assert.equal("127.0.0.1", ok.config.redis.host)
    assert.equal(6380, ok.config.redis.port)
  end)
end)
