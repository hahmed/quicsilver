#!/usr/bin/env ruby

require "bundler/setup"
require "quicsilver"

puts "🚀 Rack HTTP/3 Server Example"
puts "=" * 40

# First, set up certificates if they don't exist
unless File.exist?("certs/server.crt") && File.exist?("certs/server.key")
  puts "📝 Setting up certificates..."
  system("bash examples/setup_certs.sh")
end

# Define a simple Rack app
app = ->(env) {
  path = env['PATH_INFO']
  method = env['REQUEST_METHOD']

  case path
  when '/'
    [200,
     {'Content-Type' => 'text/plain'},
     ["Welcome to Quicsilver HTTP/3!\n"]]
  when '/api/users'
    [200,
     {'Content-Type' => 'application/json'},
     ['{"users": ["alice", "bob", "charlie"]}']]
  when '/api/status'
    [200,
     {'Content-Type' => 'application/json'},
     ["{\"status\": \"ok\", \"method\": \"#{method}\", \"path\": \"#{path}\"}"]]
  else
    [404,
     {'Content-Type' => 'text/plain'},
     ["Not Found: #{path}\n"]]
  end
}

# Create and start the server with the Rack app
server = Quicsilver::Server.new(4433, app: app)

puts "🔧 Starting server..."
server.start

puts "✅ Server is running on port 4433"
puts "📋 Try these requests:"
puts "   curl --http3 -k https://127.0.0.1:4433/"
puts "   curl --http3 -k https://127.0.0.1:4433/api/users"
puts "   curl --http3 -k https://127.0.0.1:4433/api/status"

# Keep the server running
puts "⏳ Server is running. Press Ctrl+C to stop..."
begin
  server.wait_for_connections
rescue Interrupt
  puts "\n🛑 Stopping server..."
  server.stop
  puts "👋 Server stopped"
end
