#!/usr/bin/env ruby

# Tests all major quicsilver features against a running Rails app.
#
# Prerequisites:
#   1. Start the Rails app: cd blogz && bundle exec rackup -s quicsilver -p 4433
#   2. Run this script:     cd quicsilver && bundle exec ruby examples/rails_feature_test.rb
#
# Tests: ping, streaming, priorities, echo, HEAD, multiplexing, connection pooling

require "bundler/setup"
require "quicsilver"

HOST = "localhost"
PORT = 4433
PASS = "✅"
FAIL = "❌"

def test(name)
  result = yield
  puts "  #{PASS} #{name}"
  result
rescue => e
  puts "  #{FAIL} #{name}: #{e.message}"
  nil
end

puts "Quicsilver Rails Feature Test"
puts "   Target: https://#{HOST}:#{PORT}"
puts "=" * 60

# === 1. Basic connectivity ===
puts "\n1. Basic Connectivity"
puts "-" * 60

test("GET /h3/ping returns JSON over HTTP/3") do
  response = Quicsilver::Client.get(HOST, PORT, "/h3/ping", unsecure: true)
  raise "Expected 200, got #{response.status}" unless response.status == 200
  raise "Expected JSON" unless response.body.include?('"status":"ok"')
  raise "Expected HTTP/3" unless response.body.include?("HTTP/3")
  puts "    Response: #{response.body}"
end

# === 2. Connection Pooling ===
puts "\n2. Connection Pooling"
puts "-" * 60

test("5 requests reuse one connection (no repeat handshakes)") do
  Quicsilver::Client.close_pool
  times = 5.times.map do |i|
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Quicsilver::Client.get(HOST, PORT, "/h3/ping", unsecure: true)
    elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(1)
    label = i == 0 ? "new connection + handshake" : "reused"
    puts "    Request #{i}: #{elapsed}ms (#{label})"
    elapsed
  end
  puts "    Pool: #{Quicsilver::Client.pool.size} connection(s)"
  raise "Pool should have 1 connection" unless Quicsilver::Client.pool.size == 1
  # First request includes handshake, subsequent should be faster on average
  avg_reused = times[1..].sum / times[1..].size
  puts "    First request: #{times[0]}ms, avg reused: #{avg_reused.round(1)}ms"
end

# === 3. Streaming ===
puts "\n3. Streaming Response"
puts "-" * 60

test("GET /h3/stream returns chunked SSE data") do
  response = Quicsilver::Client.get(HOST, PORT, "/h3/stream", unsecure: true)
  raise "Expected 200" unless response.status == 200
  chunks = response.body.scan(/data: chunk \d+/)
  raise "Expected 5 chunks, got #{chunks.size}" unless chunks.size == 5
  puts "    Received #{chunks.size} streamed chunks"
end

# === 4. POST with Body (Echo) ===
puts "\n4. POST with Body"
puts "-" * 60

test("POST /h3/echo returns the request body") do
  body = '{"message": "Hello HTTP/3!"}'
  response = Quicsilver::Client.post(HOST, PORT, "/h3/echo",
    body: body,
    headers: { "content-type" => "application/json" },
    unsecure: true)
  raise "Expected 200" unless response.status == 200
  raise "Body not echoed" unless response.body.include?("Hello HTTP/3!")
  puts "    Echoed: #{response.body[0..80]}"
end

# === 5. HEAD Request ===
puts "\n5. HEAD Request"
puts "-" * 60

test("HEAD /h3/head returns headers but no body") do
  client = Quicsilver::Client.new(HOST, PORT, unsecure: true)
  response = client.head("/h3/head")
  raise "Expected 200" unless response.status == 200
  raise "HEAD should have empty body" unless response.body.nil? || response.body.empty?
  puts "    Status: #{response.status}, body size: #{response.body&.bytesize || 0}"
  client.disconnect
end

# === 6. True Multiplexing (concurrent streams, single connection) ===
puts "\n6. True Multiplexing (concurrent streams, single connection)"
puts "-" * 60

test("10 concurrent requests on one connection") do
  client = Quicsilver::Client.new(HOST, PORT, unsecure: true)
  client.get("/h3/ping") # warmup + handshake

  t_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  requests = 10.times.map { client.build_request("GET", "/h3/ping") }
  responses = requests.map { |r| r.response(timeout: 10) }
  total = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_start) * 1000).round(1)

  ok = responses.count { |r| r.status == 200 }
  rps = (10 / (total / 1000.0)).round(0)
  puts "    10 concurrent requests in #{total}ms (#{ok}/10 ok, #{rps} req/s)"
  raise "Not all 200" unless ok == 10
  client.disconnect
end

# === 7. Priority Endpoints (CSS vs Image) ===
puts "\n7. Priority Endpoints"
puts "-" * 60

test("GET /h3/css returns CSS content") do
  response = Quicsilver::Client.get(HOST, PORT, "/h3/css", unsecure: true)
  raise "Expected 200" unless response.status == 200
  puts "    CSS: #{response.body.bytesize} bytes"
end

test("GET /h3/image returns large binary payload") do
  response = Quicsilver::Client.get(HOST, PORT, "/h3/image", unsecure: true)
  raise "Expected 200" unless response.status == 200
  raise "Expected 50KB" unless response.body.bytesize == 50_000
  puts "    Image: #{response.body.bytesize} bytes"
end

# === 8. Slow Response (Delay) ===
puts "\n8. Slow Response"
puts "-" * 60

test("GET /h3/slow?delay=0.2 respects delay") do
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  response = Quicsilver::Client.get(HOST, PORT, "/h3/slow?delay=0.2", unsecure: true)
  elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(1)
  raise "Expected 200" unless response.status == 200
  raise "Should take ~200ms, took #{elapsed}ms" unless elapsed > 150
  puts "    Delayed response in #{elapsed}ms"
end

# === 9. Concurrent Connections ===
puts "\n9. Concurrent Connections (4 threads, 4 connections)"
puts "-" * 60

test("4 concurrent requests on separate connections complete in parallel") do
  Quicsilver::Client.close_pool
  threads = 4.times.map do |i|
    Thread.new do
      client = Quicsilver::Client.new(HOST, PORT, unsecure: true)
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = client.get("/h3/slow?delay=0.2")
      elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(1)
      client.disconnect
      [i, response.status, elapsed]
    end
  end
  results = threads.map(&:value).sort_by(&:first)
  results.each { |i, status, elapsed| puts "    Connection #{i}: #{status} -- #{elapsed}ms" }
  total = results.map { |_, _, e| e }.max
  sequential = 200 * 4
  puts "    Total: #{total}ms (sequential would be ~#{sequential}ms)"
end

# === 10. Large Upload ===
puts "\n10. Large Upload"
puts "-" * 60

test("POST 100KB body") do
  big_body = "x" * 100_000
  response = Quicsilver::Client.post(HOST, PORT, "/h3/upload",
    body: big_body,
    headers: { "content-type" => "application/octet-stream" },
    unsecure: true)
  raise "Expected 200" unless response.status == 200
  raise "Size mismatch" unless response.body.include?('"received_bytes":100000')
  puts "    Uploaded 100KB, server received 100,000 bytes"
end

# === 11. Content-Length Validation ===
puts "\n11. Content-Length Validation"
puts "-" * 60

test("POST with content-length header") do
  body = "hello"
  response = Quicsilver::Client.post(HOST, PORT, "/h3/upload",
    body: body,
    headers: { "content-type" => "text/plain" },
    unsecure: true)
  raise "Expected 200, got #{response.status}" unless response.status == 200
  raise "Size mismatch" unless response.body.include?('"received_bytes":5')
  puts "    Sent 5 bytes, server received 5 bytes"
end

# === 12. Handshake Cost (connection pooling benefit) ===
puts "\n12. Handshake Cost"
puts "-" * 60

test("Fresh connections pay handshake cost -- pooling avoids this") do
  Quicsilver::Client.close_pool

  # First connection -- full handshake
  client1 = Quicsilver::Client.new(HOST, PORT, unsecure: true)
  t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  client1.get("/h3/ping")
  first = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1) * 1000).round(1)
  client1.disconnect

  # Second connection -- another full handshake
  client2 = Quicsilver::Client.new(HOST, PORT, unsecure: true)
  t2 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  client2.get("/h3/ping")
  second = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t2) * 1000).round(1)
  client2.disconnect

  # Pooled -- reuses existing connection, no handshake
  Quicsilver::Client.close_pool
  Quicsilver::Client.get(HOST, PORT, "/h3/ping", unsecure: true) # establish
  t3 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  Quicsilver::Client.get(HOST, PORT, "/h3/ping", unsecure: true)
  pooled = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t3) * 1000).round(1)

  puts "    Fresh connection 1: #{first}ms"
  puts "    Fresh connection 2: #{second}ms"
  puts "    Pooled (no handshake): #{pooled}ms"
end

# === 13. Server Health ===
puts "\n13. Server Health"
puts "-" * 60

test("Server still responding after all tests") do
  response = Quicsilver::Client.get(HOST, PORT, "/h3/ping", unsecure: true)
  raise "Expected 200" unless response.status == 200
  puts "    Server healthy"
end

# === 14. Rails CRUD ===
puts "\n14. Rails CRUD"
puts "-" * 60

test("GET /posts.json returns posts array") do
  response = Quicsilver::Client.get(HOST, PORT, "/posts.json", unsecure: true)
  raise "Expected 200" unless response.status == 200
  puts "    Posts: #{response.body[0..40]}"
end

# === 15. HTTP Methods ===
puts "\n15. HTTP Methods"
puts "-" * 60

client = Quicsilver::Client.new(HOST, PORT, unsecure: true)
%i[get post put patch delete head].each do |method|
  test("#{method.to_s.upcase} /h3/ping") do
    response = client.public_send(method, "/h3/ping")
    body_size = response.body&.bytesize || 0
    puts "    #{response.status} (#{body_size} bytes)"
  end
end
client.disconnect

# === Summary ===
puts "\n" + "=" * 60
puts "Feature test complete!"
puts "   Pool: #{Quicsilver::Client.pool.size} connection(s)"
Quicsilver::Client.close_pool
puts "Done"
