package = "kong-plugin-idempotency"
version = "2.0.0-1"

source = {
  url = "git://github.com/udleinati/kong-plugin-idempotency",
  tag = "2.0.0",
}

supported_platforms = {"linux", "macosx"}

description = {
   detailed = "A Kong plugin that enables idempotency for HTTP POST requests, backed by Redis.",
   homepage = "git://github.com/udleinati/kong-plugin-idempotency",
   license = "MIT"
}

-- lua-resty-redis ships with Kong/OpenResty, so it is intentionally not pinned
-- here: the plugin uses whatever version the running Kong provides.
dependencies = {
  "lua >= 5.1",
}

build = {
   type = "builtin",
   modules = {
      ["kong.plugins.idempotency.access"] = "kong/plugins/idempotency/access.lua",
      ["kong.plugins.idempotency.response"] = "kong/plugins/idempotency/response.lua",
      ["kong.plugins.idempotency.cache"] = "kong/plugins/idempotency/cache.lua",
      ["kong.plugins.idempotency.keys"] = "kong/plugins/idempotency/keys.lua",
      ["kong.plugins.idempotency.scope"] = "kong/plugins/idempotency/scope.lua",
      ["kong.plugins.idempotency.payload"] = "kong/plugins/idempotency/payload.lua",
      ["kong.plugins.idempotency.lifecycle"] = "kong/plugins/idempotency/lifecycle.lua",
      ["kong.plugins.idempotency.handler"] = "kong/plugins/idempotency/handler.lua",
      ["kong.plugins.idempotency.schema"] = "kong/plugins/idempotency/schema.lua"
   }
}
