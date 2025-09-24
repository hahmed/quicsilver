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
  
  10.times do
    client.send_data("Hello, server!")
  end
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