#!/usr/bin/env ruby
# Throughput benchmark: measures req/sec and latency percentiles.
#
# Self-contained (boots inline server):
#   REQUESTS=1000 CONNECTIONS=10 ruby benchmarks/throughput.rb
#
# External server:
#   HOST=127.0.0.1 PORT=4433 ruby benchmarks/throughput.rb

require_relative "helpers"
require "benchmark"

REQUESTS    = ENV.fetch("REQUESTS", "1000").to_i
CONNECTIONS = ENV.fetch("CONNECTIONS", "10").to_i
HOST        = ENV["HOST"]
PORT        = ENV["PORT"]&.to_i

def run_benchmark(host, port)
  Benchmarks::Helpers.print_header(
    "Quicsilver Throughput Benchmark",
    target:      "#{host}:#{port}",
    requests:    REQUESTS,
    connections: CONNECTIONS
  )

  results = []
  mutex = Mutex.new

  elapsed = Benchmark.realtime do
    per_conn = REQUESTS / CONNECTIONS

    threads = CONNECTIONS.times.map do
      Thread.new do
        client = Quicsilver::Client.new(host, port, unsecure: true)
        client.connect

        local_times = []

        per_conn.times do
          start = Time.now
          begin
            client.get("/")
            local_times << (Time.now - start)
          rescue
            local_times << nil
          end
        end

        client.disconnect
        mutex.synchronize { results.concat(local_times) }
      end
    end
    threads.each(&:join)
  end

  times  = results.compact
  failed = results.count(&:nil?)

  Benchmarks::Helpers.print_results(
    total_time:     elapsed,
    total_requests: REQUESTS,
    times:          times,
    failed:         failed
  )
end

if HOST && PORT
  run_benchmark(HOST, PORT)
else
  puts "Booting inline server..."
  Benchmarks::Helpers.with_server(Benchmarks::Helpers.benchmark_app) do |port|
    run_benchmark("127.0.0.1", port)
  end
end
