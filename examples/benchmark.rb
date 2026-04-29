#!/usr/bin/env ruby

# Quicsilver benchmark — self-contained, boots its own server.
#
#   ruby examples/benchmark.rb

require_relative "example_helper"

HOST = "localhost"
PORT = 4433
WARMUP = 10
ITERATIONS = 200

app = ->(env) {
  case env["PATH_INFO"]
  when "/large"
    [200, { "content-type" => "application/octet-stream" }, ["x" * 50_000]]
  when "/work"
    sleep 0.001
    [200, { "content-type" => "application/json" }, ['{"ok":true}']]
  else
    [200, { "content-type" => "application/json" }, ['{"ok":true}']]
  end
}

server = Quicsilver::Server.new(PORT, app: app, server_configuration: EXAMPLE_TLS_CONFIG,
  max_connections: 200)
server_thread = Thread.new { server.start }
sleep 0.3

def run_benchmark(name, iterations)
  times = iterations.times.map { yield }
  total = times.sum
  avg = (total / times.size).round(2)
  p50 = times.sort[times.size / 2].round(2)
  p99 = times.sort[(times.size * 0.99).to_i].round(2)
  rps = (times.size / (total / 1000.0)).round(0)
  puts "  Total:   #{total.round(1)}ms"
  puts "  Avg:     #{avg}ms"
  puts "  p50:     #{p50}ms"
  puts "  p99:     #{p99}ms"
  puts "  RPS:     #{rps} req/s"
end

puts "🔨 Quicsilver Benchmark"
puts "=" * 60

# === 1. Sequential (single connection) ===
puts "\n📊 Sequential — single connection, #{ITERATIONS} requests"
puts "-" * 60

client = Quicsilver::Client.new(HOST, PORT, unsecure: true)
WARMUP.times { client.get("/ping") }

run_benchmark("Sequential", ITERATIONS) do
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  client.get("/ping")
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
end
client.disconnect

# === 2. Pooled ===
puts "\n📊 Pooled — connection pool, #{ITERATIONS} requests"
puts "-" * 60

WARMUP.times { Quicsilver::Client.get(HOST, PORT, "/ping", unsecure: true) }

run_benchmark("Pooled", ITERATIONS) do
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  Quicsilver::Client.get(HOST, PORT, "/ping", unsecure: true)
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
end
Quicsilver::Client.close_pool

# === 3. Large payload ===
puts "\n📊 Large payload — 50KB response, #{ITERATIONS} requests"
puts "-" * 60

client = Quicsilver::Client.new(HOST, PORT, unsecure: true)
WARMUP.times { client.get("/large") }

run_benchmark("Large", ITERATIONS) do
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  client.get("/large")
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
end
client.disconnect

# === 4. True multiplexing ===
puts "\n📊 True multiplexing — concurrent streams, single connection"
puts "-" * 60

client = Quicsilver::Client.new(HOST, PORT, unsecure: true)
WARMUP.times { client.get("/ping") }

[1, 5, 10, 20, 50].each do |concurrent|
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  requests = concurrent.times.map { client.get("/ping") { |req| req } }
  responses = requests.map(&:response)
  elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round(1)
  ok = responses.count { |r| r[:status] == 200 }
  rps = (concurrent / (elapsed / 1000.0)).round(0)
  puts "  #{concurrent.to_s.rjust(3)} streams: #{elapsed.to_s.rjust(7)}ms  #{ok}/#{concurrent} ok  #{rps} req/s"
end
client.disconnect
Quicsilver::Client.close_pool
sleep 0.2  # let connections drain

# === 5. Multi-threaded concurrency ===
puts "\n📊 Multi-threaded — concurrent clients, #{ITERATIONS} total requests"
puts "-" * 60

[1, 2, 4, 8].each do |thread_count|
  requests_per_thread = ITERATIONS / thread_count
  err_count = 0
  mu = Mutex.new

  # Connect all clients sequentially (poll_inline holds GVL)
  clients = thread_count.times.map do
    c = Quicsilver::Client.new(HOST, PORT, unsecure: true, request_timeout: 10)
    c.open_connection
    c
  end

  # Run requests in parallel
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  threads = clients.map do |client|
    Thread.new do
      requests_per_thread.times do
        client.get("/ping")
      rescue => e
        mu.synchronize { err_count += 1 }
      end
    end
  end
  threads.each(&:join)
  elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(1)

  clients.each(&:disconnect)

  rps = (ITERATIONS / (elapsed / 1000.0)).round(0)
  err = err_count > 0 ? "  (#{err_count} errors)" : ""
  puts "  #{thread_count.to_s.rjust(3)} threads: #{elapsed.to_s.rjust(7)}ms  #{rps} req/s#{err}"
  sleep 0.1
end

# === 6. Multi-threaded with simulated work ===
puts "\n📊 Multi-threaded with 1ms app work, 50 total requests"
puts "-" * 60

[1, 2, 4, 8].each do |thread_count|
  reqs = 50
  requests_per_thread = reqs / thread_count
  err_count = 0
  mu = Mutex.new

  clients = thread_count.times.map do
    c = Quicsilver::Client.new(HOST, PORT, unsecure: true, request_timeout: 10)
    c.open_connection
    c
  end

  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  threads = clients.map do |client|
    Thread.new do
      requests_per_thread.times do
        client.get("/work")
      rescue => e
        mu.synchronize { err_count += 1 }
      end
    end
  end
  threads.each(&:join)
  elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).round(1)

  clients.each(&:disconnect)

  rps = (reqs / (elapsed / 1000.0)).round(0)
  err = err_count > 0 ? "  (#{err_count} errors)" : ""
  puts "  #{thread_count.to_s.rjust(3)} threads: #{elapsed.to_s.rjust(7)}ms  #{rps} req/s#{err}"
  sleep 0.1
end

# Cleanup
Quicsilver::Client.close_pool
server.stop
server_thread.join(2)

puts "\n" + "=" * 60
puts "✅ Benchmark complete"
