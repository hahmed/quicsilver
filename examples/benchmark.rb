#!/usr/bin/env ruby

# Benchmark quicsilver against a running server.
#
#   bundle exec rackup -s quicsilver -p 4433  (in another terminal)
#   bundle exec ruby examples/benchmark.rb

require "bundler/setup"
require "quicsilver"

HOST = "localhost"
PORT = 4433
WARMUP = 10
ITERATIONS = 100

puts "🔨 Quicsilver Benchmark"
puts "   Target: https://#{HOST}:#{PORT}"
puts "=" * 60

# === Single connection, sequential requests ===
puts "\n📊 Sequential (single connection, #{ITERATIONS} requests)"
puts "-" * 60

client = Quicsilver::Client.new(HOST, PORT, unsecure: true)

# Warmup
WARMUP.times { client.get("/h3/ping") }

times = ITERATIONS.times.map do
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  client.get("/h3/ping")
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
end

total = times.sum
avg = total / times.size
p50 = times.sort[times.size / 2]
p99 = times.sort[(times.size * 0.99).to_i]
rps = (times.size / (total / 1000.0)).round(0)

puts "  Total:   #{total.round(1)}ms"
puts "  Avg:     #{avg.round(2)}ms"
puts "  p50:     #{p50.round(2)}ms"
puts "  p99:     #{p99.round(2)}ms"
puts "  RPS:     #{rps} req/s"

client.disconnect

# === Connection pool, sequential requests ===
puts "\n📊 Pooled (connection pool, #{ITERATIONS} requests)"
puts "-" * 60

# Warmup
WARMUP.times { Quicsilver::Client.get(HOST, PORT, "/h3/ping", unsecure: true) }

times = ITERATIONS.times.map do
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  Quicsilver::Client.get(HOST, PORT, "/h3/ping", unsecure: true)
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
end

total = times.sum
avg = total / times.size
p50 = times.sort[times.size / 2]
p99 = times.sort[(times.size * 0.99).to_i]
rps = (times.size / (total / 1000.0)).round(0)

puts "  Total:   #{total.round(1)}ms"
puts "  Avg:     #{avg.round(2)}ms"
puts "  p50:     #{p50.round(2)}ms"
puts "  p99:     #{p99.round(2)}ms"
puts "  RPS:     #{rps} req/s"

Quicsilver::Client.close_pool

# === Larger payload ===
puts "\n📊 Large payload (50KB response, #{ITERATIONS} requests)"
puts "-" * 60

client = Quicsilver::Client.new(HOST, PORT, unsecure: true)

WARMUP.times { client.get("/h3/image") }

times = ITERATIONS.times.map do
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  client.get("/h3/image")
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000
end

total = times.sum
avg = total / times.size
p50 = times.sort[times.size / 2]
p99 = times.sort[(times.size * 0.99).to_i]
rps = (times.size / (total / 1000.0)).round(0)
throughput = ((50_000 * times.size) / (total / 1000.0) / 1024 / 1024).round(1)

puts "  Total:   #{total.round(1)}ms"
puts "  Avg:     #{avg.round(2)}ms"
puts "  p50:     #{p50.round(2)}ms"
puts "  p99:     #{p99.round(2)}ms"
puts "  RPS:     #{rps} req/s"
puts "  Through: #{throughput} MB/s"

client.disconnect

puts "\n" + "=" * 60
puts "✅ Benchmark complete"
