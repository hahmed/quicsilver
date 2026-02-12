#!/usr/bin/env ruby
# Throughput benchmark: measures req/sec and latency percentiles.
# Tests both sequential and concurrent (multiplexed) modes.
#
# Self-contained (boots inline server with trivial Rack app):
#   ruby benchmarks/throughput.rb
#
# External server:
#   HOST=127.0.0.1 PORT=4433 ruby benchmarks/throughput.rb

require_relative "helpers"
require "benchmark"

REQUESTS    = ENV.fetch("REQUESTS", "500").to_i
CONNECTIONS = ENV.fetch("CONNECTIONS", "5").to_i
CONCURRENCY = ENV.fetch("CONCURRENCY", "8").to_i
HOST        = ENV["HOST"]
PORT        = ENV["PORT"]&.to_i

def run_benchmark(host, port)
  # --- Sequential: 1 request at a time per connection ---
  puts "\n--- Sequential (1 stream/conn, #{CONNECTIONS} conns) ---"
  seq_times = []
  mutex = Mutex.new

  seq_elapsed = Benchmark.realtime do
    per_conn = REQUESTS / CONNECTIONS

    threads = CONNECTIONS.times.map do
      Thread.new do
        client = Quicsilver::Client.new(host, port, connection_timeout: 5000, request_timeout: 10)
        client.connect

        local = []
        per_conn.times do
          start = Time.now
          response = client.get("/")
          local << (Time.now - start) if response && response[:status] == 200
        end

        client.disconnect
        mutex.synchronize { seq_times.concat(local) }
      end
    end
    threads.each(&:join)
  end

  Benchmarks::Helpers.print_results(
    total_time: seq_elapsed, total_requests: REQUESTS,
    times: seq_times, failed: REQUESTS - seq_times.size, latency: true
  )

  # --- Concurrent: CONCURRENCY streams per connection ---
  puts "\n--- Concurrent (#{CONCURRENCY} streams/conn, #{CONNECTIONS} conns) ---"
  con_times = []
  con_failed = 0

  con_elapsed = Benchmark.realtime do
    per_conn = REQUESTS / CONNECTIONS

    threads = CONNECTIONS.times.map do
      Thread.new do
        client = Quicsilver::Client.new(host, port, connection_timeout: 5000, request_timeout: 10)
        client.connect

        local = []
        queue = Queue.new
        per_conn.times { |i| queue << i }

        workers = CONCURRENCY.times.map do
          Thread.new do
            while (queue.pop(true) rescue nil)
              start = Time.now
              response = client.get("/bench")
              dur = Time.now - start
              if response && response[:status] == 200
                local << dur
              else
                mutex.synchronize { con_failed += 1 }
              end
            end
          end
        end
        workers.each(&:join)
        client.disconnect
        mutex.synchronize { con_times.concat(local) }
      end
    end
    threads.each(&:join)
  end

  Benchmarks::Helpers.print_results(
    total_time: con_elapsed, total_requests: REQUESTS,
    times: con_times, failed: con_failed, latency: true
  )
end

Benchmarks::Helpers.print_header(
  "Quicsilver Throughput (trivial Rack app, no DB)",
  connections: CONNECTIONS,
  "reqs/conn": REQUESTS / CONNECTIONS,
  concurrency: "#{CONCURRENCY} streams/conn",
  total: REQUESTS
)

if HOST && PORT
  run_benchmark(HOST, PORT)
else
  puts "Booting inline server..."
  Benchmarks::Helpers.with_server(Benchmarks::Helpers.benchmark_app) do |port|
    run_benchmark("localhost", port)
  end
end
