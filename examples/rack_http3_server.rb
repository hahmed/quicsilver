#!/usr/bin/env ruby

require_relative "example_helper"

puts "🚀 Rack HTTP/3 Server Example"
puts "=" * 40

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

server = Quicsilver::Server.new(4433, app: app, server_configuration: EXAMPLE_TLS_CONFIG)

puts "📋 Try these requests:"
puts "   curl --http3 -k https://localhost:4433/"
puts "   curl --http3 -k https://localhost:4433/api/users"
puts "   curl --http3 -k https://localhost:4433/api/status"
puts "⏳ Press Ctrl+C to stop."
puts

server.start
