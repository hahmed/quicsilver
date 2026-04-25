# Examples

Self-contained scripts demonstrating quicsilver features. Each boots its own server — no external setup needed.

## Getting Started

```bash
# Server
ruby examples/minimal_http3_server.rb
curl --http3-only -k https://localhost:4433/

# Client
ruby examples/simple_client_test.rb
```

## Examples

| Script | Feature |
|--------|---------|
| `minimal_http3_server.rb` | Simplest HTTP/3 server |
| `rack_http3_server.rb` | Rack app with multiple routes |
| `protocol_http_server.rb` | Protocol-http mode |
| `simple_client_test.rb` | Basic client request |
| `connection_pool_demo.rb` | Connection reuse — 6ms first, 0.2ms reused |
| `feature_demo.rb` | All features in one script |
| `streaming_sse.rb` | Server-Sent Events over HTTP/3 |
| `priorities.rb` | Extensible Priorities (RFC 9218) — CSS before images |
| `trailers.rb` | Trailing headers after body |
| `grpc_style.rb` | gRPC-style request/response with JSON (no protobuf needed) |
| `falcon_middleware.rb` | Falcon's middleware stack over HTTP/3 (requires falcon gem) |
| `benchmark.rb` | Throughput benchmark |
| `rails_feature_test.rb` | 15 feature tests against a Rails app |

## Rails Integration

```bash
# 1. Add to Gemfile
gem "quicsilver"

# 2. Start
rackup -s quicsilver -p 4433

# 3. Test
curl --http3-only -k https://localhost:4433/
```

## Falcon Integration

No extra gems or config needed — just pass Falcon's middleware:

```ruby
require "falcon"
require "quicsilver"

middleware = Falcon::Server.middleware(Rails.application)
config = Quicsilver::Transport::Configuration.new(cert, key, mode: :falcon)
Quicsilver::Server.new(4433, app: middleware, server_configuration: config).start
```
