# Quicsilver

A Ruby client library for HTTP/3 and QUIC connections, powered by Microsoft's MSQUIC library.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'quicsilver'
```

And then execute:

    $ bundle install

Or install it yourself as:

    $ gem install quicsilver

## Quick Start

```ruby
require 'quicsilver'

# Simple connection with data transfer
Quicsilver.connect("example.com", 443) do |client|
  puts "Connected: #{client.connected?}"
  
  # Open bidirectional stream
  stream = client.open_bidirectional_stream
  puts "Stream opened: #{stream.opened?}"
  
  # Send data
  stream.send("Hello, QUIC World!")
  
  # Receive response (with timeout)
  response = stream.receive(timeout: 5000)
  puts "Received: #{response}"
  
  # Gracefully close sending
  stream.shutdown_send
end

# Manual connection management with multiple streams
client = Quicsilver::Client.new
client.connect("localhost", 4433)

# Send data over multiple streams
streams = 3.times.map do |i|
  stream = client.open_bidirectional_stream
  stream.send("Message #{i + 1}")
  stream
end

# Receive responses
streams.each_with_index do |stream, i|
  if stream.has_data?
    data = stream.receive
    puts "Stream #{i + 1} received: #{data}"
  end
end

# Cleanup
streams.each(&:close)
client.disconnect
```

## Features

✅ **Connection Management** - Establish secure QUIC connections  
✅ **Stream Support** - Open bidirectional and unidirectional streams  
✅ **Data Transfer** - Send and receive data over streams  
✅ **Stream Management** - Handle multiple concurrent streams with advanced features  
✅ **Advanced Connection Features** - Connection pooling, reconnection logic, health monitoring  
🚧 **HTTP/3 Support** - Higher-level HTTP/3 client functionality

## Advanced Connection Features

### Automatic Reconnection

```ruby
client = Quicsilver::Client.new(
  auto_reconnect: true,
  max_reconnect_attempts: 5,
  reconnect_delay: 1000  # 1 second, with exponential backoff
)

# Set up connection monitoring
client.set_connection_callback(:connection_lost) do
  puts "Connection lost - auto-reconnecting..."
end

client.set_connection_callback(:reconnecting) do |attempt|
  puts "Reconnecting (attempt #{attempt})..."
end

# Connect with automatic reconnection on failures
client.connect("example.com", 443)
```

### Connection Lifecycle Callbacks

```ruby
# Monitor connection events
client.set_connection_callback(:connecting) { |info| puts "Connecting to #{info[:hostname]}..." }
client.set_connection_callback(:connected) { |info| puts "Connected!" }
client.set_connection_callback(:connection_failed) { |error| puts "Failed: #{error}" }
client.set_connection_callback(:disconnected) { puts "Disconnected" }

# Get detailed connection information
info = client.connection_info
# => { connection_id: "abc123", hostname: "example.com", port: 443, 
#      uptime: 45.2, reconnect_attempts: 0, auto_reconnect: true }
```

### Connection Pooling

```ruby
# Create connection pool with load balancing
pool = Quicsilver::ConnectionPool.new(
  pool_size: 5,
  load_balance_strategy: :round_robin,  # or :least_used, :random, :least_uptime
  health_check_interval: 30,           # seconds
  # Client options for each connection
  auto_reconnect: true,
  max_concurrent_streams: 50
)

# Add target servers
pool.add_target("server1.example.com", 443)
pool.add_target("server2.example.com", 443)
pool.add_target("server3.example.com", 443)

# Start the pool
pool.start

# Use connections from pool
client = pool.get_connection
client.open_bidirectional_stream.send("data")

# Block syntax with automatic connection management
pool.with_connection do |client|
  stream = client.open_stream
  stream.send("request data")
  response = stream.receive
  puts response
end

# Broadcast to all connections in pool
pool.send_to_all_connections("broadcast message")

# Monitor pool health
stats = pool.pool_statistics
# => { pool_size: 5, total_connections: 5, healthy_connections: 4,
#      connected_connections: 4, total_streams: 12, strategy: :round_robin }

# Cleanup
pool.stop
```

### Connection Health Monitoring

```ruby
# Pool automatically monitors connection health
healthy_connections = pool.healthy_connections
unhealthy_connections = pool.unhealthy_connections

# Manual health checks and reconnection
client.connected?  # Checks actual connection status
client.reconnect if !client.connected?

# Graceful shutdown with stream cleanup
client.graceful_disconnect(timeout: 5000)
```

## Stream Management

### Basic Stream Operations

```ruby
client = Quicsilver::Client.new(max_concurrent_streams: 50)

# Stream statistics
stats = client.stream_statistics
puts "Active streams: #{stats[:active]}/#{stats[:max_concurrent]}"

# Bulk operations
client.send_to_all_streams("broadcast message")
client.close_failed_streams
client.close_all_streams

# Stream filtering
bidirectional_streams = client.find_streams(&:bidirectional)
client.each_stream { |stream| puts "Stream: #{stream.opened?}" }
```

### Stream Pool Management

```ruby
# Create managed stream pool
manager = client.create_stream_manager(
  pool_size: 10,
  load_balance_strategy: :round_robin  # or :least_used, :random
)

# Use pooled streams with load balancing
manager.send_with_pool("data")
manager.broadcast("message to all pool streams")
manager.cleanup_pool
```

### Stream Callbacks & Monitoring

```ruby
# Set up stream lifecycle callbacks
client.set_stream_callback(:stream_opened) do |stream|
  puts "New stream opened: #{stream.bidirectional ? 'bidirectional' : 'unidirectional'}"
end

client.set_stream_callback(:stream_closed) { |stream| puts "Stream closed" }
client.set_stream_callback(:stream_failed) { |stream| puts "Stream failed" }
client.set_stream_callback(:streams_cleaned) { |count| puts "Cleaned #{count} streams" }
```

### Advanced Stream Management

```ruby
# Wait for all streams to complete
client.wait_for_all_streams(timeout: 5000)

# Get different stream collections
active_streams = client.active_streams
failed_streams = client.failed_streams  
closed_streams = client.closed_streams

# Stream limits and statistics
puts "Stream count: #{client.stream_count}/#{client.max_concurrent_streams}"
detailed_stats = client.stream_statistics
# => { total: 5, active: 3, bidirectional: 4, unidirectional: 1, 
#      failed: 0, closed: 2, max_concurrent: 100 }
```

## Data Transfer API

### Sending Data

```ruby
# Send string data
stream.send("Hello World")

# Send binary data
stream.send(File.read("data.bin", mode: "rb"))

# Graceful shutdown of sending
stream.shutdown_send
```

### Receiving Data

```ruby
# Check if data is available
if stream.has_data?
  data = stream.receive
  puts "Received: #{data}"
end

# Receive with timeout
data = stream.receive(timeout: 2000) # 2 second timeout
puts "Received: #{data}" unless data.empty?
```

### Stream Types

```ruby
# Bidirectional (can send and receive)
bidi_stream = client.open_bidirectional_stream
bidi_stream.send("request")
response = bidi_stream.receive

# Unidirectional (receive-only from client perspective)
uni_stream = client.open_unidirectional_stream
# uni_stream.send("data") # This would raise an error
data = uni_stream.receive # Can receive data sent by server
```

## Current Status

🚧 **Work in Progress**

## Testing

`rake test`

## Development

After checking out the repo, run:

```bash
bundle install
rake build_msquic  # Build the MSQUIC library
rake build         # Build the gem
rake test          # Run tests
```

## Examples

See the `examples/` directory for usage examples:

- `examples/stream_example.rb` - Basic stream operations
- `examples/data_transfer_example.rb` - Send and receive data
- `examples/stream_management_example.rb` - Advanced stream management and pools
- `examples/advanced_connection_example.rb` - Connection pooling and reconnection logic
- `examples/connection_handling.rb` - Connection management

## Contributing

Bug reports and pull requests are welcome on GitHub.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
