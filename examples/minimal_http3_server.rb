#!/usr/bin/env ruby

require_relative "example_helper"

puts "🚀 Minimal HTTP/3 Server Example"
puts "=" * 40

server = Quicsilver::Server.new(4433, server_configuration: EXAMPLE_TLS_CONFIG)

puts "✅ Listening on https://localhost:4433"
puts "⏳ Press Ctrl+C to stop."
puts

server.start
