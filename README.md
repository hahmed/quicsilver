# Quicsilver

HTTP/3 server and client for Ruby with Rack support.

## Why HTTP/3?

- **No head-of-line blocking** — one slow response doesn't stall others. HTTP/2 multiplexes over TCP, but a single lost packet freezes all streams. QUIC streams are independent.
- **Faster connections** — QUIC handshake is 1 round trip (TCP+TLS is 3). Returning users get 0-RTT — zero round trips.
- **Connection migration** — users switch from wifi to cellular without dropping the connection.
- **True multiplexing** — many concurrent requests on one connection, each on its own stream.

## Features

- **HTTP/3 server** — serve any Rack app over QUIC/HTTP/3
- **HTTP/3 client** — make requests with automatic connection pooling
- **Rack integration** — `rackup -s quicsilver` works with Rails, Sinatra, any Rack app
- **Streaming** — dispatch on HEADERS, stream body chunks as they arrive
- **Extensible Priorities** (RFC 9218) — CSS before images, server respects client priority hints
- **Trailers** (RFC 9114 §4.1) — send/receive trailing headers after the body
- **GREASE** (RFC 9297) — extensibility testing on settings, frames, and streams
- **GOAWAY** (RFC 9114 §7.2.6) — graceful connection draining with validation
- **0-RTT** — fast reconnection with replay protection
- **Connection pooling** — client reuses connections automatically
- **Falcon middleware compatible** — use Falcon's caching and content encoding over HTTP/3

## Installation

```bash
git clone https://github.com/hahmed/quicsilver
cd quicsilver
bundle install
rake compile
```

## Quick Start

### Server

```ruby
require "quicsilver"
require "localhost/authority"

app = ->(env) {
  [200, {"content-type" => "text/plain"}, ["Hello HTTP/3!"]]
}

authority = Localhost::Authority.fetch
config = Quicsilver::Transport::Configuration.new(
  authority.certificate_path,
  authority.key_path
)

server = Quicsilver::Server.new(4433, app: app, server_configuration: config)
server.start
```

### Client

```ruby
require "quicsilver"

# Class-level API with automatic connection pooling.
# Clients verify TLS certificates by default, so the hostname must match the cert.
response = Quicsilver::Client.get("localhost", 4433, "/")
puts response[:status]  # => 200
puts response[:body]    # => "Hello HTTP/3!"

# POST with body
response = Quicsilver::Client.post("localhost", 4433, "/api/users",
  body: '{"name": "alice"}',
  headers: { "content-type" => "application/json" })

# Instance-level for more control. Use unsecure: true only for
# local/self-signed test servers.
client = Quicsilver::Client.new("localhost", 4433, unsecure: true)
response = client.get("/")
client.disconnect
```

### Rails

```bash
rackup -s quicsilver -p 4433
```

In development, the Rackup handler can use the `localhost` gem to generate
local certificates automatically. In production, pass both `cert_file` and
`key_file` Rackup options explicitly:

```bash
rackup -s quicsilver -p 4433 \
  -O cert_file=/path/to/fullchain.pem \
  -O key_file=/path/to/privkey.pem
```

### curl

```bash
curl --http3-only -k https://localhost:4433/
```

### TLS Certificates

HTTP/3 always runs over TLS. Core server configuration never guesses
certificate paths: `Quicsilver::Transport::Configuration` requires both a
certificate file and a private key file.

For production, point Quicsilver at the same publicly-trusted certificate and
key you use for your TCP HTTPS server:

```ruby
config = Quicsilver::Transport::Configuration.new(
  ENV.fetch("TLS_CERT_FILE"),
  ENV.fetch("TLS_KEY_FILE")
)
```

For local development, Quicsilver depends on the
[localhost](https://github.com/socketry/localhost) gem, which can generate a
certificate for `localhost` or your local development hostname:

```ruby
require "localhost/authority"

authority = Localhost::Authority.fetch
config = Quicsilver::Transport::Configuration.new(
  authority.certificate_path,
  authority.key_path
)
```

Run `bake localhost:install` once to add the localhost CA to your system trust
store. You can still use `curl -k` or `unsecure: true` for quick local testing
without trusting the CA.

Quicsilver clients verify certificates by default. Disable verification only
for local development or tests:

```ruby
client = Quicsilver::Client.new("localhost", 4433, unsecure: true)
```

### Browser Access

Any HTTP/3 client connects directly — no extra setup needed.

Browsers discover HTTP/3 via the `Alt-Svc` header from an existing HTTP/1.1
or HTTP/2 server. Run quicsilver alongside your regular Rails/Rack server on
the **same port** — TCP for HTTP/1.1+2, UDP for HTTP/3:

```bash
# Your normal Rails server (HTTP/1.1 + HTTP/2 over TCP)
bin/rails server -p 3000

# Quicsilver (HTTP/3 over UDP, same port)
rackup -s quicsilver -p 3000
```

Add the `Alt-Svc` header so browsers discover HTTP/3. The port must match
the port quicsilver is listening on:

```ruby
# config/application.rb
config.action_dispatch.default_headers["Alt-Svc"] = 'h3=":3000"; ma=86400'
```

With a publicly-trusted certificate (e.g. Let's Encrypt), browsers upgrade
to HTTP/3 automatically via Alt-Svc — no special configuration needed.

### Local Development

Both your TCP server and quicsilver need a TLS certificate trusted by
your system. Both servers **must use the same certificate**. The
`localhost` gem can generate local certificates — run `bake localhost:install`
to add the CA to your system trust store.

Chrome requires one additional flag for local development because it
does not allow QUIC connections with locally-trusted certificates:

```bash
chrome --origin-to-force-quic-on=myapp.test:3000 https://myapp.test:3000
```

This is not needed in production with publicly-trusted certificates.

## Configuration

Pass both certificate paths explicitly. Omitting either path raises a
configuration error.

```ruby
config = Quicsilver::Transport::Configuration.new(
  "certificates/server.crt",
  "certificates/server.key",
  idle_timeout_ms: 10_000,
  max_concurrent_requests: 100,
  max_body_size: 10 * 1024 * 1024,      # 10MB body limit (optional)
  max_header_size: 64 * 1024,            # 64KB header limit (optional)
  max_header_count: 128,                 # Header count limit (optional)
  stream_receive_window: 262_144,        # 256KB per stream
  connection_flow_control_window: 16_777_216  # 16MB per connection
)

server = Quicsilver::Server.new(4433, app: app, server_configuration: config)
server.start
```

## Priorities

Browsers send priority hints on requests. Quicsilver parses them and schedules high-priority streams first.

```
GET /style.css  → priority: u=0    → sent first (highest urgency)
GET /app.js     → priority: u=1    → sent second
GET /hero.png   → priority: u=5    → sent later
```

No configuration needed — it works automatically.

## Trailers

Send headers after the body — useful for checksums, streaming status, and gRPC.

```ruby
# Trailers work with protocol-http's Headers#trailer! API
headers = Protocol::HTTP::Headers.new
headers.add("content-type", "text/plain")
headers.trailer!
headers.add("x-checksum", "abc123")
```

## Falcon Middleware Mode

Use Falcon's middleware stack (caching, content encoding) over HTTP/3. Quicsilver handles the transport, Falcon's middleware handles the request pipeline:

```ruby
config = Quicsilver::Transport::Configuration.new(
  "certificates/server.crt",
  "certificates/server.key",
  mode: :falcon
)

server = Quicsilver::Server.new(4433, app: app, server_configuration: config)
server.start
```

| Mode | App Interface | Use Case |
|------|---------------|----------|
| `:rack` (default) | Rack env hash | Rails, Sinatra, any Rack app |
| `:falcon` | Protocol::HTTP::Request | Falcon middleware stack |

## Development

```bash
rake compile  # Build C extension (macOS: uses Apple clang automatically)
rake test     # Run tests
```

## License

MIT License
