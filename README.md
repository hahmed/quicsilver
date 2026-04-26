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

app = ->(env) {
  [200, {"content-type" => "text/plain"}, ["Hello HTTP/3!"]]
}

server = Quicsilver::Server.new(4433, app: app)
server.start
```

### Client

```ruby
require "quicsilver"

# Class-level API with automatic connection pooling
response = Quicsilver::Client.get("127.0.0.1", 4433, "/")
puts response[:status]  # => 200
puts response[:body]    # => "Hello HTTP/3!"

# POST with body
response = Quicsilver::Client.post("127.0.0.1", 4433, "/api/users",
  body: '{"name": "alice"}',
  headers: { "content-type" => "application/json" })

# Instance-level for more control
client = Quicsilver::Client.new("127.0.0.1", 4433, unsecure: true)
response = client.get("/")
client.disconnect
```

### Rails

```bash
rackup -s quicsilver -p 4433
```

### curl

```bash
curl --http3-only -k https://localhost:4433/
```

### Browser Access

Any HTTP/3 client connects directly — no extra setup needed.

Browsers are different — they discover HTTP/3 via the `Alt-Svc` header from an existing HTTP/1.1 or HTTP/2 server. Run quicsilver alongside your regular server:

```bash
# HTTP/1.1 on port 3000 (Puma)
rails server

# HTTP/3 on port 4433 (Quicsilver)
rackup -s quicsilver -p 4433
```

Add the `Alt-Svc` header so browsers upgrade to HTTP/3:

```ruby
# config/application.rb
config.action_dispatch.default_headers["Alt-Svc"] = 'h3=":4433"; ma=86400'
```

## Configuration

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
