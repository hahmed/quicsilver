#!/usr/bin/env ruby

require "bundler/setup"
require "quicsilver"

puts "🚀 Minimal HTTP/3 Server Example"
puts "=" * 40

# Create and start the server
server = Quicsilver::Server.new(4433)

puts "🔧 Starting server..."
server.start

puts "✅ Server is running on port 4433"
puts "📋 Server info: #{server.server_info}"

# Keep the server running
puts "⏳ Server is running. Press Ctrl+C to stop..."
begin
  server.wait_for_connections
rescue Interrupt
  puts "\n🛑 Stopping server..."
  server.stop
  puts "👋 Server stopped"
end 