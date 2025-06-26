# Quicsilver

A minimal HTTP/3 server implementation for Ruby using Microsoft's MSQUIC library.

## Features

- **Minimal HTTP/3 Server**: Basic QUIC server with TLS support
- **Minimal HTTP/3 Client**: Basic QUIC client for testing
- **TLS Certificate Support**: Self-signed certificate generation
- **Simple API**: Easy-to-use Ruby interface

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

### 2. Start the server

```bash
ruby examples/minimal_http3_server.rb
```

### 3. Connect with client

```bash
ruby examples/minimal_http3_client.rb
```

## Usage

### Server

```ruby
require "quicsilver"

# Create and start server
server = Quicsilver::Server.new(4433)
server.start

# Keep server running
server.wait_for_connections

# Stop server
server.stop
```

### Client

```ruby
require "quicsilver"

# Create client
client = Quicsilver::Client.new("127.0.0.1", 4433, unsecure: true)

# Connect
client.connect

# Check connection status
if client.connected?
  puts "Connected!"
end

# Disconnect
client.disconnect
```

## API

### Quicsilver::Server

- `new(port, address:, cert_file:, key_file:)` - Create server
- `start` - Start the server
- `stop` - Stop the server
- `running?` - Check if server is running
- `server_info` - Get server information
- `wait_for_connections(timeout:)` - Wait for connections

### Quicsilver::Client

- `new(hostname, port, unsecure:, connection_timeout:)` - Create client
- `connect` - Connect to server
- `disconnect` - Disconnect from server
- `connected?` - Check connection status
- `connection_info` - Get connection information
- `connection_uptime` - Get connection uptime

## Development

```bash
# Run tests
rake test

# Build extension
rake compile

# Clean build artifacts
rake clean
```

## Requirements

- Ruby 2.7+
- MSQUIC library
- OpenSSL for certificate generation

## License

MIT License
