local helpers = require "spec.helpers"
local redis = require "resty.redis"

local PLUGIN_NAME = "idempotency"
local REDIS_HOST = helpers.redis_host
local REDIS_PORT = helpers.redis_port
local REDIS_DATABASE = 0
local PREFIX = "kong-idempotency-plugin"
local HOST = "echo.test"

-- Mirror the key format from keys.lua so we can assert/seed Redis directly.
-- No auth here, so the consumer scope is "anonymous".
local function lock_key(path, idem)
  return PREFIX .. ":anonymous:" .. HOST .. ":" .. path .. ":POST:" .. idem
end
local function response_key(path, idem)
  return lock_key(path, idem) .. "-response"
end

local function redis_connect()
  local red = redis:new()
  red:set_timeout(2000)
  assert(red:connect(REDIS_HOST, REDIS_PORT))
  assert(red:select(REDIS_DATABASE))
  return red
end

-- Case-insensitive response header lookup.
local function header(res, name)
  return res.headers[name] or res.headers[name:lower()]
end

for _, strategy in helpers.each_strategy() do
  describe(PLUGIN_NAME .. ": (access) [#" .. strategy .. "]", function()
    local proxy_client

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, { "routes", "services", "plugins" }, { PLUGIN_NAME })

      -- Kong's built-in mock upstream: /request echoes the received request
      -- (headers included) back as JSON. Each route strips its own path so the
      -- upstream always sees /request.
      local echo_service = bp.services:insert({
        name = "echo-service",
        url = "http://" .. helpers.mock_upstream_host .. ":" .. helpers.mock_upstream_port .. "/request",
      })

      local function add_plugin(path, config)
        local route = bp.routes:insert({ service = echo_service, paths = { path } })
        bp.plugins:insert({ name = PLUGIN_NAME, route = route, config = config })
      end

      -- Optional key (default behaviour), nested redis config.
      add_plugin("/echo", {
        redis_cache_time = 60,
        redis = { host = REDIS_HOST, port = REDIS_PORT, database = REDIS_DATABASE },
      })

      -- Key required.
      add_plugin("/required", {
        is_required = true,
        redis_cache_time = 60,
        redis = { host = REDIS_HOST, port = REDIS_PORT, database = REDIS_DATABASE },
      })

      -- Legacy flat redis_* config (backwards compatibility).
      add_plugin("/legacy", {
        redis_cache_time = 60,
        redis_host = REDIS_HOST,
        redis_port = REDIS_PORT,
        redis_database = REDIS_DATABASE,
      })

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
      -- Start each test from a clean Redis so the first request is always new.
      local red = redis_connect()
      assert(red:flushall())
      red:close()
      proxy_client = helpers.proxy_client()
    end)

    after_each(function()
      if proxy_client then proxy_client:close() end
    end)

    it("proxies the first request and stores the response in Redis", function()
      local res = proxy_client:post("/echo", {
        headers = { host = HOST, ["X-Idempotency-Key"] = "first-1", ["Content-Type"] = "application/json" },
        body = "{}",
      })
      assert.response(res).has.status(200)
      assert.equal("completed", header(res, "X-Idempotency-Status"))

      local red = redis_connect()
      local key = response_key("/echo", "first-1")
      assert.not_equal(ngx.null, red:get(key), "the response should have been cached")
      local ttl = red:ttl(key)
      assert.is_true(ttl > 0 and ttl <= 60, "the cached response should carry the configured ttl")
      red:close()
    end)

    it("replays the cached response for a duplicate key", function()
      -- First request carries a marker the echo upstream reflects into its body.
      local res1 = proxy_client:post("/echo", {
        headers = {
          host = HOST,
          ["X-Idempotency-Key"] = "dup-1",
          ["X-Test"] = "first",
          ["Content-Type"] = "application/json",
        },
        body = "{}",
      })
      assert.response(res1).has.status(200)
      local json1 = assert.response(res1).has.jsonbody()
      assert.equal("first", json1.headers["x-test"])
      proxy_client:close()

      -- Second request with the same key but a different marker must receive the
      -- ORIGINAL (cached) body, proving it was served from the cache.
      proxy_client = helpers.proxy_client()
      local res2 = proxy_client:post("/echo", {
        headers = {
          host = HOST,
          ["X-Idempotency-Key"] = "dup-1",
          ["X-Test"] = "second",
          ["Content-Type"] = "application/json",
        },
        body = "{}",
      })
      assert.response(res2).has.status(200)
      assert.equal("completed", header(res2, "X-Idempotency-Status"))
      local json2 = assert.response(res2).has.jsonbody()
      assert.equal("first", json2.headers["x-test"], "duplicate must see the cached response, not its own request")
    end)

    it("returns 409 while the original request is still in flight", function()
      -- Seed only the lock (no cached response yet) to simulate an in-flight
      -- original request.
      local red = redis_connect()
      assert(red:set(lock_key("/echo", "inflight-1"), "1", "EX", 60))
      red:close()

      local res = proxy_client:post("/echo", {
        headers = { host = HOST, ["X-Idempotency-Key"] = "inflight-1", ["Content-Type"] = "application/json" },
        body = "{}",
      })
      assert.response(res).has.status(409)
      assert.equal("waiting_response", header(res, "X-Idempotency-Status"))
    end)

    it("rejects a required-key request that omits the key", function()
      local res = proxy_client:post("/required", {
        headers = { host = HOST, ["Content-Type"] = "application/json" },
        body = "{}",
      })
      assert.response(res).has.status(400)
    end)

    it("rejects a required-key request sending an empty key", function()
      local res = proxy_client:post("/required", {
        headers = { host = HOST, ["X-Idempotency-Key"] = "", ["Content-Type"] = "application/json" },
        body = "{}",
      })
      assert.response(res).has.status(400)
    end)

    it("passes a keyless request through when the key is optional", function()
      local res = proxy_client:post("/echo", {
        headers = { host = HOST, ["Content-Type"] = "application/json" },
        body = "{}",
      })
      assert.response(res).has.status(200)
      assert.is_nil(header(res, "X-Idempotency-Status"))
    end)

    it("ignores non-POST requests", function()
      local res = proxy_client:get("/echo", {
        headers = { host = HOST, ["X-Idempotency-Key"] = "get-1" },
      })
      assert.response(res).has.status(200)
      assert.is_nil(header(res, "X-Idempotency-Status"))
    end)

    it("works with the legacy flat redis_* configuration", function()
      local res = proxy_client:post("/legacy", {
        headers = { host = HOST, ["X-Idempotency-Key"] = "leg-1", ["Content-Type"] = "application/json" },
        body = "{}",
      })
      assert.response(res).has.status(200)
      assert.equal("completed", header(res, "X-Idempotency-Status"))

      local red = redis_connect()
      assert.not_equal(ngx.null, red:get(response_key("/legacy", "leg-1")))
      red:close()
    end)
  end)
end
