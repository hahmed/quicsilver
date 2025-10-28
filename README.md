# Quicsilver

HTTP/3 server for Ruby with Rack support.

Disclaimer: currenly in early prototype.

## Installation

```bash
git clone <repository>
cd quicsilver
bundle install
rake compile
```

## Quick Start

### 1. Set up certificates

```bash
bash examples/setup_certs.sh
```

### 2. Run a Rack app over HTTP/3

```ruby
require "quicsilver"

# Define your Rack app
app = ->(env) {
  path = env['PATH_INFO']

  case path
  when '/'
    [200, {'Content-Type' => 'text/plain'}, ["Hello HTTP/3!"]]
  when '/api/users'
    [200, {'Content-Type' => 'application/json'}, ['{"users": ["alice", "bob"]}']]
  else
    [404, {'Content-Type' => 'text/plain'}, ["Not Found"]]
  end
}

# Start HTTP/3 server with Rack app
server = Quicsilver::Server.new(4433, app: app)
server.start
server.wait_for_connections
```

### 3. Test with the client

```bash
ruby examples/minimal_http3_client.rb
```

## Usage

### Rack HTTP/3 Server

```ruby
require "quicsilver"

app = ->(env) {
  [200, {'Content-Type' => 'text/html'}, ["<h1>Hello from HTTP/3!</h1>"]]
}

server = Quicsilver::Server.new(4433, app: app)
server.start
server.wait_for_connections
```

### HTTP/3 Client

```ruby
require "quicsilver"

client = Quicsilver::Client.new("127.0.0.1", 4433, unsecure: true)
client.connect

# Send HTTP/3 request
request = Quicsilver::HTTP3::RequestEncoder.new(
  method: 'GET',
  path: '/api/users',
  authority: 'example.com'
)
client.send_data(request.encode)

client.disconnect
```

## Development

```bash
# Run tests
rake test

# Build extension
rake compile

# Clean build artifacts
rake clean
```

## License

MIT License
