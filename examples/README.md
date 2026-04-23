# Quicsilver Examples

This directory contains examples for testing your Ruby QUIC implementation.

All examples use `example_helper.rb` which uses the [`localhost`](https://github.com/socketry/localhost) gem to generate self-signed TLS certificates — **no manual certificate setup needed**.

In production, you must provide your own cert/key paths to `Quicsilver::Transport::Configuration.new`.

## 🚀 Quick Start

### 1. Run the Server

```bash
# Terminal 1 — pick any example:
ruby examples/minimal_http3_server.rb
ruby examples/rack_http3_server.rb
ruby examples/protocol_http_server.rb
```

### 2. Test the Connection

```bash
# Terminal 2
curl --http3 -k https://localhost:4433/

# Or use the client example (requires a server running)
ruby examples/simple_client_test.rb
```

## 📁 Files

| File | Purpose |
|------|---------|
| `example_helper.rb` | Shared helper — sets up TLS via `localhost` gem |
| `minimal_http3_server.rb` | Bare-minimum HTTP/3 server |
| `rack_http3_server.rb` | Rack app with multiple routes |
| `protocol_http_server.rb` | Rack app using protocol-http internally |
| `simple_client_test.rb` | QUIC client test |

## ✅ Expected Output

**Server:**
```
🚀 Minimal HTTP/3 Server Example
════════════════════════════════════════
🔧 Starting server...
✅ Server is running on port 4433
⏳ Server is running. Press Ctrl+C to stop...
```

**Client:**
```
🔌 Simple HTTP/3 Client Test
════════════════════════════════════════
Status: 200
Headers: {"content-type"=>"text/plain"}
Body: Hello from Quicsilver!
👋 Done
```

## 🔧 Custom Certificates

If you need to use your own certificates instead of the `localhost` gem:

```ruby
config = Quicsilver::Transport::Configuration.new(
  "/path/to/server.crt",
  "/path/to/server.key"
)
server = Quicsilver::Server.new(4433, app: app, server_configuration: config)
```
