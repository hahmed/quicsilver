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

puts "🚀 Quicsilver Rails Feature Test"
puts "   Target: https://#{HOST}:#{PORT}"
puts "=" * 60

# === 1. Basic connectivity ===
puts "\n1️⃣  Basic Connectivity"
puts "-" * 60

test("GET /h3/ping returns JSON over HTTP/3") do
  response = Quicsilver::Client.get(HOST, PORT, "/h3/ping", unsecure: true)
  raise "Expected 200, got #{response[:status]}" unless response[:status] == 200
  raise "Expected JSON" unless response[:body].include?('"status":"ok"')
  raise "Expected HTTP/3" unless response[:body].include?("HTTP/3")
  puts "    Response: #{response[:body]}"
end

# === 2. Connection Pooling ===
puts "\n2️⃣  Connection Pooling"
puts "-" * 60

test("Multiple requests reuse the same connection") do
  5.times do |i|
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Quicsilver::Client.get(HOST, PORT, "/h3/ping", unsecure: true)
    elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(1)
    puts "    Request #{i}: #{elapsed}ms (#{i == 0 ? 'new connection' : 'same connection'})"
  end
  puts "    Pool: #{Quicsilver::Client.pool.size} connection(s)"
  raise "Pool should have 1 connection" unless Quicsilver::Client.pool.size == 1
end

# === 3. Streaming ===
puts "\n3️⃣  Streaming Response"
puts "-" * 60

test("GET /h3/stream returns chunked SSE data") do
  response = Quicsilver::Client.get(HOST, PORT, "/h3/stream", unsecure: true)
  raise "Expected 200" unless response[:status] == 200
  chunks = response[:body].scan(/data: chunk \d+/)
  raise "Expected 5 chunks, got #{chunks.size}" unless chunks.size == 5
  puts "    Received #{chunks.size} streamed chunks"
end

# === 4. POST with Body (Echo) ===
puts "\n4️⃣  POST with Body"
puts "-" * 60

test("POST /h3/echo returns the request body") do
  body = '{"message": "Hello HTTP/3!"}'
  response = Quicsilver::Client.post(HOST, PORT, "/h3/echo",
    body: body,
    headers: { "content-type" => "application/json" },
    unsecure: true)
  raise "Expected 200" unless response[:status] == 200
  raise "Body not echoed" unless response[:body].include?("Hello HTTP/3!")
  puts "    Echoed: #{response[:body][0..80]}"
end

# === 5. HEAD Request ===
puts "\n5️⃣  HEAD Request"
puts "-" * 60

test("HEAD /h3/head returns headers but no body") do
  client = Quicsilver::Client.new(HOST, PORT, unsecure: true)
  response = client.head("/h3/head")
  raise "Expected 200" unless response[:status] == 200
  raise "HEAD should have empty body" unless response[:body].nil? || response[:body].empty?
  puts "    Status: #{response[:status]}, body size: #{response[:body]&.bytesize || 0}"
  client.disconnect
end

# === 6. Multiplexing (Sequential on single connection) ===
puts "\n6️⃣  Multiplexing (10 requests, single connection)"
puts "-" * 60

test("10 sequential requests on one connection") do
  client = Quicsilver::Client.new(HOST, PORT, unsecure: true)
  t_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  10.times { client.get("/h3/ping") }
  total = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t_start) * 1000).round(1)
  puts "    10 requests in #{total}ms (single connection)"
  client.disconnect
end

# === 7. Priority Endpoints (CSS vs Image) ===
puts "\n7️⃣  Priority Endpoints"
puts "-" * 60

test("GET /h3/css returns CSS content") do
  response = Quicsilver::Client.get(HOST, PORT, "/h3/css", unsecure: true)
  raise "Expected 200" unless response[:status] == 200
  puts "    CSS: #{response[:body].bytesize} bytes"
end

test("GET /h3/image returns large binary payload") do
  response = Quicsilver::Client.get(HOST, PORT, "/h3/image", unsecure: true)
  raise "Expected 200" unless response[:status] == 200
  raise "Expected 50KB" unless response[:body].bytesize == 50_000
  puts "    Image: #{response[:body].bytesize} bytes"
end

# === 8. Slow Response (Delay) ===
puts "\n8️⃣  Slow Response"
puts "-" * 60

test("GET /h3/slow?delay=0.2 respects delay") do
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  response = Quicsilver::Client.get(HOST, PORT, "/h3/slow?delay=0.2", unsecure: true)
  elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(1)
  raise "Expected 200" unless response[:status] == 200
  raise "Should take ~200ms, took #{elapsed}ms" unless elapsed > 150
  puts "    Delayed response in #{elapsed}ms"
end

# === 9. Rails CRUD ===
puts "\n9️⃣  Rails CRUD"
puts "-" * 60

test("GET /posts.json returns posts array") do
  response = Quicsilver::Client.get(HOST, PORT, "/posts.json", unsecure: true)
  raise "Expected 200" unless response[:status] == 200
  puts "    Posts: #{response[:body][0..40]}"
end

test("POST /h3/echo round-trips JSON body") do
  body = '{"post": {"name": "HTTP/3 Post", "title": "Created over QUIC!"}}'
  response = Quicsilver::Client.post(HOST, PORT, "/h3/echo",
    body: body,
    headers: { "content-type" => "application/json" },
    unsecure: true)
  raise "Expected 200" unless response[:status] == 200
  raise "Body not echoed" unless response[:body].include?("HTTP/3 Post")
  puts "    Round-tripped #{body.bytesize} bytes of JSON"
end

# === 10. HTTP Methods ===
puts "\n🔟  HTTP Methods"
puts "-" * 60

client = Quicsilver::Client.new(HOST, PORT, unsecure: true)
%i[get post put patch delete head].each do |method|
  test("#{method.to_s.upcase} /h3/ping") do
    response = client.public_send(method, "/h3/ping")
    body_size = response[:body]&.bytesize || 0
    puts "    #{response[:status]} (#{body_size} bytes)"
  end
end
client.disconnect

# === Summary ===
puts "\n" + "=" * 60
puts "🏁 Feature test complete!"
puts "   Pool: #{Quicsilver::Client.pool.size} connection(s)"
Quicsilver::Client.close_pool
puts "👋 Done"
