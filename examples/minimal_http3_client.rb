#!/usr/bin/env ruby

require "bundler/setup"
require "quicsilver"

puts "🔌 Minimal HTTP/3 Client Example"
puts "=" * 40

# Create client
client = Quicsilver::Client.new("127.0.0.1", 4433, unsecure: true)

puts "🔧 Connecting to server..."
begin
  client.connect
  puts "✅ Connected successfully!"
  puts "📋 Connection info: #{client.connection_info}"
  
  # HTTP/3-style requests (most realistic for QUIC)
  client.send_data("GET /api/users HTTP/3\r\nHost: example.com\r\n\r\n")
  client.send_data("GET /api/posts/123 HTTP/3\r\nHost: example.com\r\n\r\n")
  client.send_data("POST /api/messages HTTP/3\r\nContent-Length: 25\r\n\r\n{\"text\":\"Hello world\"}")

  # JSON payloads (API requests)
  client.send_data('{"action":"subscribe","channel":"orders"}')
  client.send_data('{"action":"update","user_id":42,"status":"online"}')
  client.send_data('{"query":"SELECT * FROM users WHERE id=1"}')

  # WebSocket-like messages
  client.send_data("PING")
  client.send_data("SUBSCRIBE:stock.prices")
  client.send_data("MSG:user123:Hey there")

  # Metrics/telemetry
  # client.send_data("METRIC:cpu=45.2,mem=1024,ts=#{Time.now.to_i}")
  # client.send_data("EVENT:login,user=alice,ip=192.168.1.100")
  
  # You send this large message:
  client.send_data("X" * 50000)  # 50KB

  # Keep connection alive for a bit
  puts "⏳ Connection established. Press Enter to disconnect..."
  gets
  
rescue Quicsilver::ConnectionError => e
  puts "❌ Connection failed: #{e.message}"
rescue Quicsilver::TimeoutError => e
  puts "⏰ Connection timed out: #{e.message}"
ensure
  puts "🔌 Disconnecting..."
  client.disconnect
  puts "👋 Disconnected"
end 