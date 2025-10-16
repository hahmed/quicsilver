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
  
  http3_get_request = [
    # Frame type: HEADERS (0x01)
    0x01,

    # Frame length: ~40 bytes (will vary)
    0x28,

    # QPACK encoded headers (RFC 9204)
    # Prefix: Required Insert Count = 0, S = 0, Delta Base = 0
    0x00, 0x00,

    # :method = GET (literal with name from static table)
    0x50, 0x03, 0x47, 0x45, 0x54,  # "GET"

    # :path = / 
    0x51, 0x01, 0x2f,  # "/"

    # :scheme = https
    0x57, 0x05, 0x68, 0x74, 0x74, 0x70, 0x73,  # "https"

    # :authority = localhost:4433
    0x50, 0x0f,
    0x6c, 0x6f, 0x63, 0x61, 0x6c, 0x68, 0x6f, 0x73, 0x74,  # "localhost"
    0x3a, 0x34, 0x34, 0x33, 0x33  # ":4433"
  ].pack('C*')

  client.send_data(http3_get_request)
  # Minimal HTTP/3 GET / request, that sends the binary data directly:
  client.send_data("\x01\x10\x00\x00\x50\x03GET\x51\x01/\x57\x05https")

  # WebSocket-like messages
  client.send_data("PING")
  client.send_data("SUBSCRIBE:stock.prices")

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