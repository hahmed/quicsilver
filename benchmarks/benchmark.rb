#!/usr/bin/env ruby
# Usage: REQUESTS=1000 CONNECTIONS=10 ruby benchmarks/benchmark.rb

require 'bundler/setup'
require 'quicsilver'
require 'benchmark'

REQUESTS    = ENV.fetch('REQUESTS', 1000).to_i
CONNECTIONS = ENV.fetch('CONNECTIONS', 1).to_i
HOST        = ENV.fetch('HOST', '127.0.0.1')
PORT        = ENV.fetch('PORT', 4433).to_i

puts "Quicsilver HTTP/3 Benchmark"
puts "=" * 50
puts "Target: #{HOST}:#{PORT}"
puts "Requests: #{REQUESTS} | Connections: #{CONNECTIONS}"
puts "=" * 50

results = []
mutex = Mutex.new

elapsed = Benchmark.realtime do
  threads = CONNECTIONS.times.map do |conn_id|
    Thread.new do
      client = Quicsilver::Client.new(HOST, PORT, unsecure: true)
      client.connect

      local_times = []
      per_conn = REQUESTS / CONNECTIONS

      per_conn.times do |i|
        start = Time.now
        begin
          client.get("/")
          local_times << (Time.now - start)
        rescue
          local_times << nil
        end
        print "." if conn_id == 0 && i % (per_conn / 10).clamp(1, 100) == 0
      end

      client.disconnect
      mutex.synchronize { results.concat(local_times) }
    end
  end
  threads.each(&:join)
end

times = results.compact
failed = results.count(&:nil?)

puts "\n" + "=" * 50
puts "RESULTS"
puts "=" * 50
puts "Total:    #{elapsed.round(3)}s"
puts "Req/sec:  #{(REQUESTS / elapsed).round(2)}"
puts "Success:  #{times.size} | Failed: #{failed}"

if times.any?
  sorted = times.sort
  puts "Latency:  avg=#{(times.sum / times.size * 1000).round(2)}ms " \
       "min=#{(sorted.first * 1000).round(2)}ms " \
       "max=#{(sorted.last * 1000).round(2)}ms"
  puts "          p50=#{(sorted[sorted.size / 2] * 1000).round(2)}ms " \
       "p95=#{(sorted[(sorted.size * 0.95).to_i] * 1000).round(2)}ms " \
       "p99=#{(sorted[(sorted.size * 0.99).to_i] * 1000).round(2)}ms"
end
puts "=" * 50
