local mocks = require "spec.01-unit.support.mocks"

-- scope.from_request() reads the PDK, so it is driven through the fake kong.

local function build(request)
  local kong_mock = mocks.fake_kong({ request = request })
  return mocks.load_with("kong.plugins.idempotency.scope", {
    kong = kong_mock,
    ngx = mocks.fake_ngx(),
  })
end

describe("idempotency scope", function()

  it("builds the descriptor keys are namespaced within", function()
    -- host/path/method/consumer are exactly the dimensions keys.lua scopes by;
    -- this is the single place they are read off the request.
    local scope = build({
      method = "PUT", path = "/orders", host = "api.test", consumer = { id = "c-9" },
    })
    assert.same(
      { host = "api.test", path = "/orders", method = "PUT", consumer = "c-9" },
      scope.from_request()
    )
  end)

  it("uses a nil consumer for an unauthenticated request", function()
    -- No consumer -> keys.prefix() falls back to the "anonymous" scope; it must
    -- not blow up reaching for consumer.id.
    local scope = build({ method = "POST", path = "/p", host = "h" })
    assert.is_nil(scope.from_request().consumer)
  end)
end)
