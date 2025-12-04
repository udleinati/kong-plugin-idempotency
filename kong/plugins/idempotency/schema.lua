local typedefs = require "kong.db.schema.typedefs"

return {
  name = "idempotency",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http },
    { config = {
      type = "record",
      fields = {
        { is_required = { type = "boolean", default = false, }, },
        { redis_host = typedefs.host },
        { redis_port = typedefs.port({ default = 6379 }), },
        { redis_cache_time = { type = "number" }, },
        { redis_password = { type = "string", len_min = 0, referenceable = true }, },
        { redis_username = { type = "string", referenceable = true }, },
        { redis_ssl = { type = "boolean", required = true, default = false, }, },
        { redis_ssl_verify = { type = "boolean", required = true, default = false }, },
        { redis_database = { type = "integer", default = 0 }, },
        { redis_server_name = typedefs.sni },
        { redis_timeout = { type = "number", default = 2000, }, },
        { redis_prefix = { type = "string", default = "kong-idempotency-plugin"}, },
      },
    }, },
  }
}
