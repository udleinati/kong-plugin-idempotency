const http = require('http');
const crypto = require('crypto');
const zlib = require('zlib');

const hostname = '0.0.0.0';
const port = process.env.PORT || 3200;

function head(req, name) {
  const v = req.headers[name];
  return Array.isArray(v) ? v[0] : v;
}

// Echo service. Every response carries a fresh, random `X-Upstream-Id` header
// (and a JSON `id`) so a cached/replayed response is easy to spot — it keeps the
// original id. Optional control headers let the demo/edge tests drive behaviour:
//   X-Echo-Status: <code>     respond with this status code
//   X-Echo-Delay:  <ms>       sleep before responding (for concurrency tests)
//   X-Echo-Header: Name: Val  add a custom response header
//   X-Echo-Binary: 1          respond with a binary (non-UTF-8) body
const server = http.createServer((req, res) => {
  req.on('data', () => {}); // drain the request body
  req.on('end', () => {
    const id = crypto.randomUUID();
    const status = parseInt(head(req, 'x-echo-status') || '200', 10) || 200;
    const delay = parseInt(head(req, 'x-echo-delay') || '0', 10) || 0;
    const extra = head(req, 'x-echo-header'); // "Name: Value"
    const binary = head(req, 'x-echo-binary') === '1';

    const send = () => {
      // Chaos: abruptly drop the connection mid-flight (simulate an upstream
      // crash / RST) so we can see how the plugin behaves on a failed original.
      if (head(req, 'x-echo-reset') === '1') {
        res.socket.destroy();
        return;
      }

      res.statusCode = status;
      res.setHeader('X-Upstream-Id', id);

      if (extra) {
        const i = extra.indexOf(':');
        if (i > 0) res.setHeader(extra.slice(0, i).trim(), extra.slice(i + 1).trim());
      }

      if (binary) {
        res.setHeader('Content-Type', 'application/octet-stream');
        // 8 random bytes (so fresh responses differ) + every byte 0x00..0xff.
        const buf = Buffer.concat([
          crypto.randomBytes(8),
          Buffer.from(Array.from({ length: 256 }, (_, i) => i)),
        ]);
        res.end(buf);
      } else {
        res.setHeader('Content-Type', 'application/json');
        const body = JSON.stringify({
          id,
          timestamp: new Date().toISOString(),
          method: req.method,
          path: req.url,
          headers: req.headers,
        });
        if (head(req, 'x-echo-gzip') === '1') {
          res.setHeader('Content-Encoding', 'gzip');
          res.end(zlib.gzipSync(Buffer.from(body)));
        } else {
          res.end(body);
        }
      }
    };

    if (delay > 0) setTimeout(send, delay); else send();
  });
});

server.listen(port, hostname, () => {
  console.log(`Echo service running on port ${port}`);
});

process.on('SIGINT', () => process.exit());
process.on('SIGTERM', () => process.exit());
