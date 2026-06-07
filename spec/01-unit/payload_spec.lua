local payload = require "kong.plugins.idempotency.payload"
local cjson = require "cjson"

-- payload owns the stored-response contract: what gets encoded, which headers
-- are dropped, and what counts as a valid value to replay. Pure, so these specs
-- drive it directly.

describe("idempotency payload", function()

  describe("encode()", function()
    it("round-trips status, body and surviving headers", function()
      local stored = cjson.decode(payload.encode({
        status = 201, body = "created", headers = { ["content-type"] = "application/json" },
      }))
      assert.equal(201, stored.status)
      assert.equal("created", stored.body)
      assert.equal("application/json", stored.headers["content-type"])
    end)

    it("strips hop-by-hop and length headers that must not be replayed verbatim", function()
      -- These are recomputed by Kong when the body is re-sent on replay; storing
      -- them would corrupt the replayed response.
      local stored = cjson.decode(payload.encode({
        status = 200, body = "ok",
        headers = {
          ["content-type"] = "text/plain",
          ["connection"] = "keep-alive",
          ["content-length"] = "2",
          ["transfer-encoding"] = "chunked",
          ["x-idempotency-status"] = "completed",
        },
      }))
      assert.equal("text/plain", stored.headers["content-type"])
      assert.is_nil(stored.headers["connection"])
      assert.is_nil(stored.headers["content-length"])
      assert.is_nil(stored.headers["transfer-encoding"])
      assert.is_nil(stored.headers["x-idempotency-status"])
    end)

    it("tolerates a response with no headers", function()
      assert.has_no.errors(function()
        payload.encode({ status = 204, body = "" })
      end)
    end)
  end)

  describe("decode()", function()
    it("returns the response for a well-formed payload", function()
      local replay = payload.decode(payload.encode({ status = 200, body = "x", headers = {} }))
      assert.equal(200, replay.status)
      assert.equal("x", replay.body)
    end)

    it("returns nil for a non-JSON value", function()
      -- A foreign/corrupt value at the response key must not crash the request.
      assert.is_nil(payload.decode("not json {"))
    end)

    it("returns nil for JSON that is not an object", function()
      -- e.g. some other writer left a bare number under the key.
      assert.is_nil(payload.decode("1"))
    end)

    it("returns nil for an object missing a status", function()
      -- Without a status there is nothing replayable -- treat as in-flight.
      assert.is_nil(payload.decode('{"body":"x"}'))
    end)
  end)

  describe("encode -> decode", function()
    it("preserves a response across a storage round-trip", function()
      local replay = payload.decode(payload.encode({
        status = 418, body = "teapot", headers = { ["x-resource-id"] = "42" },
      }))
      assert.equal(418, replay.status)
      assert.equal("teapot", replay.body)
      assert.equal("42", replay.headers["x-resource-id"])
    end)
  end)
end)
