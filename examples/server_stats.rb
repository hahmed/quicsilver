#!/usr/bin/env ruby
# frozen_string_literal: true

# Demonstrates Quicsilver::Server#stats.
#
#   ruby examples/server_stats.rb
#   PORT=4444 ruby examples/server_stats.rb
#
# The stats snapshot combines:
#   - Quicsilver app-server state: running, connections, active requests, queue.
#   - QUIC transport counters: process-wide connection/stream/packet/worker state.

require_relative "example_helper"
require "json"

HOST = ENV.fetch("HOST", "localhost")
PORT = Integer(ENV.fetch("PORT", "4433"))

server = nil
server_thread = nil
clients = []

begin
app = ->(env) {
  case env["PATH_INFO"]
  when "/hello"
    [200, { "content-type" => "text/plain" }, ["hello\n"]]
  when %r{\A/slow}
    sleep 0.25
    [200, { "content-type" => "text/plain" }, ["slow response\n"]]
  else
    [404, { "content-type" => "text/plain" }, ["not found\n"]]
  end
}

server = Quicsilver::Server.new(PORT, app: app, server_configuration: EXAMPLE_TLS_CONFIG)
server_thread = Thread.new { server.start }

# Keep examples self-contained without requiring test helpers.
def wait_until(timeout: 3)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  until yield
    raise "timed out waiting" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    sleep 0.01
  end
end

wait_until { server.running? }

# Print the useful subset first, then include the whole transport hash so it is
# easy to see every counter name currently exposed by Quicsilver.transport_counters.
def print_stats(title, server)
  stats = server.stats
  transport = stats["transport"] || {}

  puts "\n#{title}"
  puts "-" * title.length
  puts JSON.pretty_generate(
    "server" => {
      "running" => stats["running"],
      "shutting_down" => stats["shutting_down"],
      "connections" => stats["connections"],
      "requests" => stats["requests"],
      "scheduler" => stats["scheduler"]
    },
    "transport_summary" => {
      "connections_active" => transport["connections_active"],
      "connections_connected" => transport["connections_connected"],
      "streams_active" => transport["streams_active"],
      "connection_queue_depth" => transport["connection_queue_depth"],
      "connection_operations_queue_depth" => transport["connection_operations_queue_depth"],
      "worker_operations_queue_depth" => transport["worker_operations_queue_depth"],
      "connections_load_rejected" => transport["connections_load_rejected"],
      "packets_dropped" => transport["packets_dropped"],
      "app_bytes_received" => transport["app_bytes_received"],
      "app_bytes_sent" => transport["app_bytes_sent"]
    },
    "transport" => transport
  )
end

puts "Quicsilver Server Stats Demo"
puts "Listening on https://#{HOST}:#{PORT}"
puts "Note: transport counters are process-wide, so they include this example's clients too."

print_stats("1. Fresh server", server)

clients = 2.times.map { Quicsilver::Client.new(HOST, PORT, unsecure: true) }
clients.each_with_index do |client, index|
  response = client.get("/hello")
  puts "client #{index + 1}: GET /hello -> #{response.status}"
end

wait_until { server.stats.dig("connections", "active") >= 2 }
print_stats("2. After two client connections", server)

slow_requests = clients.each_with_index.map do |client, index|
  Thread.new do
    response = client.get("/slow/#{index + 1}")
    puts "client #{index + 1}: GET /slow/#{index + 1} -> #{response.status}"
  end
end

wait_until { server.stats.dig("requests", "active") >= 2 }
print_stats("3. While slow requests are in flight", server)

slow_requests.each(&:join)
print_stats("4. After slow requests complete", server)

puts "\nDone."
ensure
  clients.each { |client| client.disconnect rescue nil }
  Quicsilver::Client.close_pool rescue nil
  server&.stop rescue nil
  server_thread&.join(2)
end
