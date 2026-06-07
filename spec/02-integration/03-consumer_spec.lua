local helpers = require "spec.helpers"
local redis = require "resty.redis"

local PLUGIN_NAME = "idempotency"
local REDIS_HOST = helpers.redis_host
local REDIS_PORT = helpers.redis_port

local function redis_connect()
  local red = redis:new()
  red:set_timeout(2000)
  assert(red:connect(REDIS_HOST, REDIS_PORT))
  assert(red:select(0))
  return red
end

-- The idempotency key is scoped per authenticated consumer, so two different
-- consumers reusing the same key must NOT receive each other's responses.
for _, strategy in helpers.each_strategy() do
  describe(PLUGIN_NAME .. ": (consumer scoping) [#" .. strategy .. "]", function()
    local proxy_client

    lazy_setup(function()
      local bp = helpers.get_db_utils(
        strategy,
        { "routes", "services", "plugins", "consumers", "keyauth_credentials" },
        { PLUGIN_NAME, "key-auth" }
      )

      local echo = bp.services:insert({
        name = "consumer-echo",
        url = "http://" .. helpers.mock_upstream_host .. ":" .. helpers.mock_upstream_port .. "/request",
      })
      local route = bp.routes:insert({ service = echo, paths = { "/c-auth" } })
      bp.plugins:insert({ name = "key-auth", route = route })
      bp.plugins:insert({
        name = PLUGIN_NAME,
        route = route,
        config = { redis_cache_time = 60, redis = { host = REDIS_HOST, port = REDIS_PORT } },
      })

      local alice = bp.consumers:insert({ username = "alice" })
      bp.keyauth_credentials:insert({ consumer = alice, key = "alice-key" })
      local bob = bp.consumers:insert({ username = "bob" })
      bp.keyauth_credentials:insert({ consumer = bob, key = "bob-key" })

      assert(helpers.start_kong({
        database = strategy,
        plugins = "bundled," .. PLUGIN_NAME,
        nginx_conf = "spec/fixtures/custom_nginx.template",
      }))
    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    before_each(function()
      local red = redis_connect()
      assert(red:flushall())
      red:close()
      proxy_client = helpers.proxy_client()
    end)

    after_each(function()
      if proxy_client then proxy_client:close() end
    end)

    it("does not leak a response across consumers reusing the same key", function()
      -- alice's request (echoed apikey proves whose request was processed)
      local res1 = proxy_client:post("/c-auth", {
        headers = { ["apikey"] = "alice-key", ["X-Idempotency-Key"] = "shared", ["Content-Type"] = "application/json" },
        body = "{}",
      })
      assert.response(res1).has.status(200)
      assert.equal("alice-key", (assert.response(res1).has.jsonbody()).headers["apikey"])
      proxy_client:close()

      -- bob reuses the same key: must get his own (fresh) response, not alice's
      proxy_client = helpers.proxy_client()
      local res2 = proxy_client:post("/c-auth", {
        headers = { ["apikey"] = "bob-key", ["X-Idempotency-Key"] = "shared", ["Content-Type"] = "application/json" },
        body = "{}",
      })
      assert.response(res2).has.status(200)
      assert.equal("bob-key", (assert.response(res2).has.jsonbody()).headers["apikey"],
                   "bob must not receive alice's cached response")
    end)
  end)
end
