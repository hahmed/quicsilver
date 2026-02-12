# Quicsilver

HTTP/3 server for Ruby with Rack support.

**Status:** Experimental (v0.2.0)

## Installation

```bash
git clone <repository>
cd quicsilver
bundle install
rake compile
```

## Quick Start

### Server

```ruby
require "quicsilver"

app = ->(env) {
  case env['PATH_INFO']
  when '/'
    [200, {'content-type' => 'text/plain'}, ["Hello HTTP/3!"]]
  when '/api/users'
    [200, {'content-type' => 'application/json'}, ['{"users": ["alice", "bob"]}']]
  else
    [404, {'content-type' => 'text/plain'}, ["Not Found"]]
  end
}

server = Quicsilver::Server.new(4433, app: app)
server.start  # Blocks until shutdown
```

### Client

```ruby
require "quicsilver"

client = Quicsilver::Client.new("127.0.0.1", 4433, unsecure: true)
client.connect

response = client.get("/api/users")
puts response[:body]

response = client.post("/api/users", body: '{"name": "charlie"}')

client.disconnect
```

## Usage with Rails

```bash
rackup -s quicsilver -p 4433
```

## Configuration

```ruby
config = Quicsilver::ServerConfiguration.new("/path/to/cert.pem", "/path/to/key.pem",
  idle_timeout_ms: 10_000,        # Connection idle timeout (ms)
  max_concurrent_requests: 100    # Max concurrent requests per connection
)

server = Quicsilver::Server.new(4433,
  app: app,
  address: "0.0.0.0",
  server_configuration: config
)
```

## Development

```bash
rake compile  # Build C extension
rake test     # Run tests
rake clean    # Clean build artifacts
```

## License

MIT License
