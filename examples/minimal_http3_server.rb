#!/usr/bin/env ruby

require "bundler/setup"
require "quicsilver"

puts "🚀 Minimal HTTP/3 Server Example"
puts "=" * 40

# First, set up certificates if they don't exist
unless File.exist?("certs/server.crt") && File.exist?("certs/server.key")
  puts "📝 Setting up certificates..."
  system("bash examples/setup_certs.sh")
end

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