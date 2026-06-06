local typedefs = require "kong.db.schema.typedefs"
local redis_schema = require "kong.tools.redis.schema"

-- Fold a legacy flat `redis_*` config value into the shared `config.redis.*`
-- record. Keeps configs written for the pre-3.6 (flat) schema working.
local function redis_shorthand(field, extra)
  local def = {
    type = (extra and extra.type) or "string",
    func = function(value)
      return { redis = { [field] = value } }
    end,
  }
  if extra then
    def.referenceable = extra.referenceable
    def.len_min = extra.len_min
  end
  return { ["redis_" .. field] = def }
end

return {
  name = "idempotency",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
      type = "record",
      fields = {
        -- When false, requests without an X-Idempotency-Key are passed through
        -- untouched; when true, such requests are rejected with 400.
        { is_required = { type = "boolean", default = false }, },

        -- TTL (seconds) of both the idempotency lock and the cached response,
        -- i.e. the window during which a key is considered a duplicate.
        -- Integer: Redis `SET ... EX` only accepts whole seconds.
        { redis_cache_time = { type = "integer", required = true, default = 86400, gt = 0 }, },

        -- Namespace prepended to every Redis key.
        { redis_prefix = { type = "string", required = true, default = "kong-idempotency-plugin" }, },

        -- Shared Kong Redis config record (Kong 3.6+): exposes config.redis.host,
        -- config.redis.port, config.redis.ssl, config.redis.username, etc.
        { redis = redis_schema.config_schema },
      },
      -- Backwards compatibility: accept the legacy flat redis_* keys and fold
      -- them into the config.redis.* record above.
      shorthand_fields = {
        redis_shorthand("host"),
        redis_shorthand("port", { type = "integer" }),
        redis_shorthand("password", { referenceable = true, len_min = 0 }),
        redis_shorthand("username", { referenceable = true }),
        redis_shorthand("ssl", { type = "boolean" }),
        redis_shorthand("ssl_verify", { type = "boolean" }),
        redis_shorthand("server_name"),
        redis_shorthand("timeout", { type = "number" }),
        redis_shorthand("database", { type = "integer" }),
      },
    }, },
  },
  entity_checks = {
    -- Redis is mandatory for this plugin: it has nowhere else to store keys.
    { custom_entity_check = {
        field_sources = { "config" },
        run_with_missing_fields = true,
        fn = function(entity)
          local redis = entity.config and entity.config.redis
          if not redis or redis.host == nil or redis.host == ngx.null then
            return nil, "config.redis.host is required"
          end
          return true
        end,
    } },
  },
}
