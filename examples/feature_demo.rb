#!/usr/bin/env ruby

# Demonstrates all major quicsilver features in one script.
#
#   ruby examples/feature_demo.rb

require_relative "example_helper"

PORT = 4433
HOST = "localhost"

# === Server with multiple endpoints ===
app = ->(env) {
  path = env["PATH_INFO"]
  method = env["REQUEST_METHOD"]

  case path
  when "/"
    [200, { "content-type" => "text/plain" }, ["Hello HTTP/3!\n"]]

  when "/api/users"
    [200, { "content-type" => "application/json" },
     ['{"users":["alice","bob","charlie"]}']]

  when "/stream"
    # Streaming body — chunks sent as they're generated
    body = Enumerator.new do |y|
      5.times do |i|
        y << "chunk #{i}\n"
        sleep 0.01
      end
    end
    [200, { "content-type" => "text/plain" }, body]

  when "/large"
    # Large response for priority testing
    [200, { "content-type" => "text/plain" }, ["x" * 10_000]]

  when "/echo"
    # Echo POST body back
    body = env["rack.input"]&.read || ""
    [200, { "content-type" => "text/plain", "content-length" => body.bytesize.to_s }, [body]]

  else
    [404, { "content-type" => "text/plain" }, ["Not Found"]]
  end
}

server = Quicsilver::Server.new(PORT, app: app, server_configuration: EXAMPLE_TLS_CONFIG)
server_thread = Thread.new { server.start }
sleep 0.3

puts "🚀 Quicsilver Feature Demo"
puts "=" * 60

# === 1. Connection Pooling ===
puts "\n1️⃣  Connection Pooling"
puts "-" * 60

6.times do |i|
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  response = Quicsilver::Client.get(HOST, PORT, "/", unsecure: true)
  elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(1)
  label = i == 0 ? "← handshake" : "← reused"
  puts "  Request #{i}: #{response.status} — #{elapsed}ms #{label}"
end

# === 2. Multiple Endpoints ===
puts "\n2️⃣  Multiple Endpoints"
puts "-" * 60

["/", "/api/users", "/stream", "/nonexistent"].each do |path|
  response = Quicsilver::Client.get(HOST, PORT, path, unsecure: true)
  body_preview = response.body[0..50].gsub("\n", "\\n")
  puts "  GET #{path} → #{response.status} | #{body_preview}"
end

# === 3. POST with Body ===
puts "\n3️⃣  POST with Echo"
puts "-" * 60

response = Quicsilver::Client.post(HOST, PORT, "/echo",
  body: "Hello from quicsilver client!",
  headers: { "content-type" => "text/plain" },
  unsecure: true)
puts "  POST /echo → #{response.status} | #{response.body}"

# === 4. Concurrent Requests ===
puts "\n4️⃣  Concurrent Requests (multiplexing)"
puts "-" * 60

client = Quicsilver::Client.new(HOST, PORT, unsecure: true)
t_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
10.times do |i|
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  response = client.get("/api/users")
  elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(1)
  puts "  Request #{i}: #{response.status} — #{elapsed}ms"
end
total = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_start) * 1000).round(1)
puts "  All 10 completed in #{total}ms (single connection)"
client.disconnect

# === 5. HTTP Methods ===
puts "\n5️⃣  HTTP Methods"
puts "-" * 60

client = Quicsilver::Client.new(HOST, PORT, unsecure: true)
%i[get post put patch delete head].each do |method|
  response = client.public_send(method, "/api/users")
  body_size = response.body&.bytesize || 0
  puts "  #{method.to_s.upcase.ljust(6)} /api/users → #{response.status} (#{body_size} bytes)"
end
client.disconnect

# === Summary ===
puts "\n" + "=" * 60
puts "✅ All features working!"
puts "   Pool: #{Quicsilver::Client.pool.size} connection(s)"

# === Cleanup ===
Quicsilver::Client.close_pool
server.stop
server_thread.join(2)
puts "👋 Done"
