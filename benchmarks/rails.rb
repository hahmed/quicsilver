#!/usr/bin/env ruby
# Rails benchmark: concurrent POST, GET, DELETE against a Rails app.
# Multiplexes requests within each connection (HTTP/3 streams),
# capped by CONCURRENCY to stay within the server's stream limit.
#
# Start blogz first:
#   cd ../blogz && bundle exec rackup -s quicsilver -p 4433
#
# Usage:
#   CONNECTIONS=5 ITERATIONS=100 ruby benchmarks/rails.rb
#   CONCURRENCY=8 CONNECTIONS=3 ITERATIONS=200 ruby benchmarks/rails.rb

require "bundler/setup"
require "quicsilver"
require "json"
require "benchmark"

require_relative "helpers"

HOST        = ENV.fetch("HOST", "127.0.0.1")
PORT        = ENV.fetch("PORT", "4433").to_i
CONNECTIONS = ENV.fetch("CONNECTIONS", "5").to_i
ITERATIONS  = ENV.fetch("ITERATIONS", "100").to_i
CONCURRENCY = ENV.fetch("CONCURRENCY", "8").to_i  # max in-flight per connection

total_requests = CONNECTIONS * ITERATIONS

Benchmarks::Helpers.print_header(
  "Rails Concurrent Benchmark (multiplexed)",
  target:      "#{HOST}:#{PORT}",
  connections: CONNECTIONS,
  "reqs/conn": ITERATIONS,
  concurrency: "#{CONCURRENCY} streams/conn",
  total:       "#{total_requests * 3} (POST + GET + DELETE)"
)

mutex = Mutex.new
results = { post: [], get: [], delete: [] }
all_created_ids = []

# Fire N requests with at most `concurrency` in-flight at a time on a shared connection.
def multiplex(count, concurrency:)
  queue = Queue.new
  count.times { |i| queue << i }

  threads = concurrency.times.map do
    Thread.new do
      while (i = queue.pop(true) rescue nil)
        yield i
      end
    end
  end
  threads.each(&:join)
end

# Phase 1: Concurrent multiplexed POSTs
puts "\nPhase 1: POST /posts.json (#{CONNECTIONS} conns x #{ITERATIONS}, #{CONCURRENCY} in-flight)..."
post_elapsed = Benchmark.realtime do
  conn_threads = CONNECTIONS.times.map do |conn_id|
    Thread.new do
      client = Quicsilver::Client.new(HOST, PORT, unsecure: true)
      client.connect

      local_times = []
      local_ids = []

      multiplex(ITERATIONS, concurrency: CONCURRENCY) do |i|
        start = Time.now
        response = client.post(
          "/posts.json",
          headers: { "content-type" => "application/json" },
          body: { post: { name: "Author #{conn_id}-#{i}", title: "Post #{conn_id}-#{i}" } }.to_json
        )
        elapsed = Time.now - start

        if response && response[:status] == 201
          body = JSON.parse(response[:body]) rescue {}
          mutex.synchronize do
            local_times << elapsed
            local_ids << body["id"] if body["id"]
          end
        end
      end

      client.disconnect
      mutex.synchronize do
        results[:post].concat(local_times)
        all_created_ids.concat(local_ids)
      end
    end
  end
  conn_threads.each(&:join)
end
puts "  #{results[:post].size} created in #{post_elapsed.round(2)}s (#{(results[:post].size / post_elapsed).round(1)} req/s)"

# Phase 2: Concurrent multiplexed GETs
puts "\nPhase 2: GET /posts.json (#{CONNECTIONS} conns x #{ITERATIONS}, #{CONCURRENCY} in-flight)..."
get_elapsed = Benchmark.realtime do
  conn_threads = CONNECTIONS.times.map do
    Thread.new do
      client = Quicsilver::Client.new(HOST, PORT, unsecure: true)
      client.connect

      local_times = []

      multiplex(ITERATIONS, concurrency: CONCURRENCY) do |_i|
        start = Time.now
        response = client.get("/posts.json")
        elapsed = Time.now - start

        if response && response[:status] == 200
          mutex.synchronize { local_times << elapsed }
        end
      end

      client.disconnect
      mutex.synchronize { results[:get].concat(local_times) }
    end
  end
  conn_threads.each(&:join)
end
puts "  #{results[:get].size} fetched in #{get_elapsed.round(2)}s (#{(results[:get].size / get_elapsed).round(1)} req/s)"

# Phase 3: Concurrent multiplexed DELETEs
delete_count = all_created_ids.size
puts "\nPhase 3: DELETE /posts/:id (#{delete_count} across #{CONNECTIONS} conns, #{CONCURRENCY} in-flight)..."
delete_elapsed = Benchmark.realtime do
  id_chunks = all_created_ids.each_slice((all_created_ids.size.to_f / CONNECTIONS).ceil).to_a

  conn_threads = id_chunks.map do |ids|
    Thread.new do
      next if ids.empty?

      client = Quicsilver::Client.new(HOST, PORT, unsecure: true)
      client.connect

      local_times = []

      multiplex(ids.size, concurrency: CONCURRENCY) do |i|
        start = Time.now
        response = client.delete("/posts/#{ids[i]}.json")
        elapsed = Time.now - start

        if response && response[:status] == 204
          mutex.synchronize { local_times << elapsed }
        end
      end

      client.disconnect
      mutex.synchronize { results[:delete].concat(local_times) }
    end
  end
  conn_threads.each(&:join)
end
puts "  #{results[:delete].size} deleted in #{delete_elapsed.round(2)}s (#{(results[:delete].size / delete_elapsed).round(1)} req/s)"

# Summary
total_elapsed = post_elapsed + get_elapsed + delete_elapsed
total_completed = results.values.sum(&:size)

puts
puts "=" * 70
puts "RESULTS"
puts "=" * 70
Benchmarks::Helpers.print_stats("POST   /posts.json", results[:post])
Benchmarks::Helpers.print_stats("GET    /posts.json", results[:get])
Benchmarks::Helpers.print_stats("DELETE /posts/:id ", results[:delete])
puts "-" * 70
puts "  Total: #{total_completed} requests in #{total_elapsed.round(2)}s (#{(total_completed / total_elapsed).round(2)} req/s)"
puts "=" * 70
