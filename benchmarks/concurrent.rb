#!/usr/bin/env ruby
# Concurrency benchmark: tests HTTP/3 multiplexing and multi-connection overhead.
#
# Self-contained:
#   ruby benchmarks/concurrent.rb
#
# External server:
#   HOST=127.0.0.1 PORT=4433 ruby benchmarks/concurrent.rb

require_relative "helpers"
require "benchmark"

MULTIPLEX_REQUESTS = ENV.fetch("MULTIPLEX_REQUESTS", "50").to_i
NUM_CLIENTS        = ENV.fetch("NUM_CLIENTS", "20").to_i
REQUESTS_PER_CLIENT = ENV.fetch("REQUESTS_PER_CLIENT", "5").to_i
HOST = ENV["HOST"]
PORT = ENV["PORT"]&.to_i

def test_multiplexing(host, port)
  Benchmarks::Helpers.print_header(
    "Test 1: Single-connection multiplexing",
    requests: MULTIPLEX_REQUESTS
  )

  request_times = []
  mutex = Mutex.new

  client = Quicsilver::Client.new(host, port, unsecure: true)
  client.connect

  elapsed = Benchmark.realtime do
    threads = MULTIPLEX_REQUESTS.times.map do |i|
      Thread.new do
        start = Time.now
        client.get("/multiplex/#{i}")
        req_time = Time.now - start
        mutex.synchronize { request_times << req_time }
      end
    end
    threads.each(&:join)
  end

  client.disconnect

  concurrency_factor = request_times.any? ? (request_times.sum / elapsed).round(2) : 0
  puts "  Wall clock:          #{(elapsed * 1000).round(2)}ms"
  puts "  Avg request time:    #{(request_times.sum / request_times.size * 1000).round(2)}ms"
  puts "  Throughput:          #{(MULTIPLEX_REQUESTS / elapsed).round(2)} req/s"
  puts "  Concurrency factor:  #{concurrency_factor}x"
  Benchmarks::Helpers.print_stats("Latency", request_times)
end

def test_concurrent_clients(host, port)
  Benchmarks::Helpers.print_header(
    "Test 2: Concurrent clients",
    clients:            NUM_CLIENTS,
    requests_per_client: REQUESTS_PER_CLIENT
  )

  request_times = []
  mutex = Mutex.new
  successful = 0

  elapsed = Benchmark.realtime do
    threads = NUM_CLIENTS.times.map do |i|
      Thread.new do
        client = Quicsilver::Client.new(host, port, unsecure: true)
        client.connect

        REQUESTS_PER_CLIENT.times do |req|
          start = Time.now
          client.get("/client#{i}/request#{req}")
          req_time = Time.now - start
          mutex.synchronize { request_times << req_time }
        end

        client.disconnect
        mutex.synchronize { successful += 1 }
      rescue => e
        $stderr.puts "  Client #{i} error: #{e.message}"
      end
    end
    threads.each(&:join)
  end

  total_requests = request_times.size
  concurrency_factor = request_times.any? ? (request_times.sum / elapsed).round(2) : 0

  puts "  Successful clients:  #{successful}/#{NUM_CLIENTS}"
  puts "  Total requests:      #{total_requests}"
  puts "  Wall clock:          #{(elapsed * 1000).round(2)}ms"
  puts "  Avg request time:    #{request_times.any? ? (request_times.sum / request_times.size * 1000).round(2) : "N/A"}ms"
  puts "  Throughput:          #{(total_requests / elapsed).round(2)} req/s"
  puts "  Concurrency factor:  #{concurrency_factor}x"
  Benchmarks::Helpers.print_stats("Latency", request_times)
end

def run_all(host, port)
  test_multiplexing(host, port)
  test_concurrent_clients(host, port)
end

if HOST && PORT
  run_all(HOST, PORT)
else
  puts "Booting inline server..."
  Benchmarks::Helpers.with_server(Benchmarks::Helpers.benchmark_app) do |port|
    run_all("127.0.0.1", port)
  end
end
