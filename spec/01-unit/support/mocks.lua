-- Lightweight mocks so the plugin's Lua modules can be unit-tested without a
-- running Kong / OpenResty. Each builder records the side effects we care about
-- (headers set, redis commands, logs) so specs can assert on them.

local M = {}

-- ---------------------------------------------------------------------------
-- ngx
-- ---------------------------------------------------------------------------
function M.fake_ngx()
  return {
    null = setmetatable({}, { __tostring = function() return "ngx.null" end }),
  }
end

-- ---------------------------------------------------------------------------
-- kong PDK
-- ---------------------------------------------------------------------------
-- opts.request describes the incoming request:
--   method, path, headers (table keyed by exact header name)
-- opts.response describes the upstream response (for the response phase):
--   status, body, headers (table)
function M.fake_kong(opts)
  opts = opts or {}
  local req = opts.request or {}
  local res = opts.response or {}

  local recorded = {
    response_headers = {}, -- kong.response.set_header
    logs = {},             -- kong.log.err
    exit = nil,            -- kong.response.exit args
  }

  -- kong.ctx.plugin persists across phases for the same plugin instance.
  local plugin_ctx = opts.plugin_ctx or {}

  local kong = {
    ctx = { plugin = plugin_ctx },
    request = {
      get_method = function() return req.method or "POST" end,
      get_path = function() return req.path or "/" end,
      get_host = function() return req.host or "example.test" end,
      get_header = function(name) return (req.headers or {})[name] end,
    },
    client = {
      -- req.consumer is a table like { id = "c1" } or nil
      get_consumer = function() return req.consumer end,
    },
    response = {
      set_header = function(name, value)
        recorded.response_headers[name] = value
      end,
      get_headers = function()
        -- return a shallow copy so the module can mutate it freely
        local copy = {}
        for k, v in pairs(res.headers or {}) do copy[k] = v end
        return copy
      end,
      exit = function(status, body, headers)
        recorded.exit = { status = status, body = body, headers = headers }
      end,
    },
    service = {
      response = {
        get_status = function() return res.status or 200 end,
        get_raw_body = function() return res.body or "" end,
      },
    },
    log = {
      err = function(...)
        local parts = {}
        for i = 1, select("#", ...) do
          parts[i] = tostring(select(i, ...))
        end
        recorded.logs[#recorded.logs + 1] = table.concat(parts)
      end,
    },
  }

  return kong, recorded, plugin_ctx
end

-- ---------------------------------------------------------------------------
-- resty.redis client
-- ---------------------------------------------------------------------------
-- Records every command and replies with whatever the spec configures:
--   opts.set_return        -> reply for :set (default "OK")
--   opts.set_err           -> error for :set
--   opts.get_return        -> reply for :get
--   opts.get_err           -> error for :get
--   opts.connect_fail      -> make :connect fail
--   opts.reused_times      -> reply for :get_reused_times (default 0)
function M.fake_redis_client(opts)
  opts = opts or {}
  local red = {
    calls = {
      timeout = {}, connect = {}, auth = {}, select = {},
      set = {}, get = {}, keepalive = {},
    },
  }

  function red:set_timeout(t) self.calls.timeout[#self.calls.timeout + 1] = t end

  function red:connect(host, port, sock_opts)
    self.calls.connect[#self.calls.connect + 1] = { host = host, port = port, sock_opts = sock_opts }
    if opts.connect_fail then return nil, "connect failed" end
    return 1
  end

  function red:get_reused_times() return opts.reused_times or 0 end

  function red:auth(...)
    self.calls.auth[#self.calls.auth + 1] = { ... }
    return 1
  end

  function red:select(db)
    self.calls.select[#self.calls.select + 1] = db
    return 1
  end

  function red:set(key, value, ...)
    self.calls.set[#self.calls.set + 1] = { key = key, value = value, args = { ... } }
    if opts.set_err then return nil, opts.set_err end
    if opts.set_return ~= nil then return opts.set_return end
    return "OK"
  end

  function red:get(key)
    self.calls.get[#self.calls.get + 1] = key
    if opts.get_err then return nil, opts.get_err end
    return opts.get_return
  end

  function red:set_keepalive(a, b)
    self.calls.keepalive[#self.calls.keepalive + 1] = { a, b }
    return 1
  end

  local module = { new = function() return red end }
  return module, red
end

-- ---------------------------------------------------------------------------
-- cache module (connection + release)
-- ---------------------------------------------------------------------------
-- A drop-in for kong.plugins.idempotency.cache used by the access/response
-- specs: hands back the given client and records release() calls.
function M.fake_cache(client)
  local calls = { connection = 0, release = {} }
  local cache = {
    connection = function()
      calls.connection = calls.connection + 1
      return client
    end,
    release = function(red)
      calls.release[#calls.release + 1] = red
    end,
  }
  return cache, calls
end

-- ---------------------------------------------------------------------------
-- Module loading with mocks installed
-- ---------------------------------------------------------------------------
function M.load_with(modpath, env)
  local prev_loaded = {}

  _G.kong = env.kong
  _G.ngx = env.ngx

  for name, mod in pairs(env.packages or {}) do
    prev_loaded[name] = package.loaded[name]
    package.loaded[name] = mod
  end

  -- force a fresh load of the module under test
  local prev_self = package.loaded[modpath]
  package.loaded[modpath] = nil

  local ok, result = pcall(require, modpath)

  -- keep the module-under-test unloaded so the next build re-requires it with
  -- its own mocks; restore unrelated package.loaded entries
  package.loaded[modpath] = prev_self
  for name, mod in pairs(prev_loaded) do
    package.loaded[name] = mod
  end

  if not ok then
    error(result)
  end

  return result
end

return M
