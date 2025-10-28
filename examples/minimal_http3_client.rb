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
  
  # HTTP/3 requests using RequestEncoder
  require_relative '../lib/quicsilver/http3/request_encoder'

  request1 = Quicsilver::HTTP3::RequestEncoder.new(
    method: 'GET',
    path: '/api/users',
    authority: 'example.com'
  )
  client.send_data(request1.encode)

  request2 = Quicsilver::HTTP3::RequestEncoder.new(
    method: 'GET',
    path: '/api/posts/123',
    authority: 'example.com'
  )
  client.send_data(request2.encode)

  request3 = Quicsilver::HTTP3::RequestEncoder.new(
    method: 'POST',
    path: '/api/messages',
    authority: 'example.com',
    body: '{"text":"Hello world"}'
  )
  client.send_data(request3.encode)

  # JSON payloads (API requests) - now as proper HTTP/3 POST requests
  request4 = Quicsilver::HTTP3::RequestEncoder.new(
    method: 'POST',
    path: '/api/subscribe',
    authority: 'example.com',
    headers: { 'content-type' => 'application/json' },
    body: '{"action":"subscribe","channel":"orders"}'
  )
  client.send_data(request4.encode)

  request5 = Quicsilver::HTTP3::RequestEncoder.new(
    method: 'POST',
    path: '/api/update',
    authority: 'example.com',
    headers: { 'content-type' => 'application/json' },
    body: '{"action":"update","user_id":42,"status":"online"}'
  )
  client.send_data(request5.encode)

  # These old manually-crafted requests use incorrect QPACK indices - removed

  # Metrics/telemetry
  # client.send_data("METRIC:cpu=45.2,mem=1024,ts=#{Time.now.to_i}")
  # client.send_data("EVENT:login,user=alice,ip=192.168.1.100")
  
  # Large message test - now as HTTP/3 request
  request8 = Quicsilver::HTTP3::RequestEncoder.new(
    method: 'POST',
    path: '/upload',
    authority: 'example.com',
    body: "X" * 50000  # 50KB
  )
  client.send_data(request8.encode)

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