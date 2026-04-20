#!/usr/bin/env ruby

# Demonstrates connection pooling.
#
#   ruby examples/connection_pool_demo.rb
#
# To compare with main (no pooling), checkout main and run:
#
#   ruby examples/simple_client_test.rb
#
# Each request on main pays the full QUIC handshake cost.
# With pooling, only the first request pays it.

require_relative "example_helper"

PORT = 4433
HOST = "localhost"

# Start a simple server in-process
app = ->(env) { [200, { "content-type" => "text/plain" }, ["Hello from #{env['PATH_INFO']}"]] }
server = Quicsilver::Server.new(PORT, app: app, server_configuration: EXAMPLE_TLS_CONFIG)
server_thread = Thread.new { server.start }
sleep 0.3

puts "Connection Pool Demo"
puts "=" * 50

puts "\n🔄 Client.get — pooling is automatic"
puts "-" * 50

6.times do |i|
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  response = Quicsilver::Client.get(HOST, PORT, "/request-#{i}", unsecure: true)
  elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(1)

  label = i == 0 ? "← new connection + QUIC handshake" : "← reused"
  puts "  Request #{i}: #{response[:status]} — #{elapsed}ms #{label}"
end

puts "\n  Pool: #{Quicsilver::Client.pool.size} connection(s) ready for reuse"

# --- Cleanup ---
Quicsilver::Client.close_pool
server.stop
server_thread.join(2)

puts "\n✅ Done"
