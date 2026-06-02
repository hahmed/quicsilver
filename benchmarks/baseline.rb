#!/usr/bin/env ruby
# frozen_string_literal: true

# Quicsilver baseline benchmark with a single-file Rails app.
#
# Examples:
#   ruby benchmarks/baseline.rb
#   REQUESTS=5000 ruby benchmarks/baseline.rb
#   WORKLOAD=big REQUESTS=50 ruby benchmarks/baseline.rb
#   CONNECTIONS=1 STREAMS=4 ruby benchmarks/baseline.rb
#   WORKLOAD=sleep SLEEP_SECONDS=0.1 REQUESTS=100 ruby benchmarks/baseline.rb

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "benchmark"
require "localhost/authority"
require "quicsilver"
require_relative "helpers"

REQUESTS = Integer(ENV.fetch("REQUESTS", "10"))
CONNECTIONS = Integer(ENV.fetch("CONNECTIONS", "1"))
STREAMS = Integer(ENV.fetch("STREAMS", "1"))
WORKERS = Integer(ENV.fetch("WORKERS", "5"))
WORKLOAD = ENV.fetch("WORKLOAD", "tiny")
SLEEP_SECONDS = Float(ENV.fetch("SLEEP_SECONDS", "0.1"))
PORT = Integer(ENV.fetch("PORT", Benchmarks.random_port.to_s))
PATH = Benchmarks.path_for(WORKLOAD)
APP = Benchmarks.rails_app(sleep_seconds: SLEEP_SECONDS, secret_key_base: "quicsilver-benchmark")

def start_server
  authority = Localhost::Authority.fetch
  config = Quicsilver::Transport::Configuration.new(authority.certificate_path, authority.key_path)
  server = Quicsilver::Server.new(
    PORT,
    address: "127.0.0.1",
    app: APP,
    server_configuration: config,
    threads: WORKERS,
  )

  thread = Thread.new { server.start }
  thread.abort_on_exception = true
  wait_for_server(thread)
  [server, thread]
end

def wait_for_server(thread)
  deadline = Time.now + 10

  while Time.now < deadline
    abort "server exited while booting" unless thread.alive?

    begin
      client = Quicsilver::Client.new("127.0.0.1", PORT, connection_timeout: 500, request_timeout: 1)
      client.open_connection
      response = client.get("/")
      return if response&.status == 200
      warn "readiness check returned HTTP #{response&.status}: #{response&.body&.byteslice(0, 120).inspect}" if ENV["DEBUG"]
    rescue StandardError => error
      warn "readiness check failed: #{error.class}: #{error.message}" if ENV["DEBUG"]
      sleep 0.1
    ensure
      client&.disconnect rescue nil
    end
  end

  abort "server failed to boot: quicsilver://127.0.0.1:#{PORT}"
end

def stop_server(server, thread)
  server&.stop rescue nil
  thread&.join(5)
end

def start_request(connection, path)
  connection.get(path) { |request| request }
end

def finish_request(request)
  request.response
end

def request(connection, path)
  finish_request(start_request(connection, path))
end

def open_connections
  Array.new(CONNECTIONS) do
    Quicsilver::Client.new("127.0.0.1", PORT, connection_timeout: 5000, request_timeout: 10).tap(&:open_connection)
  end
end

def measure
  connections = open_connections
  # Untimed request per connection to warm Rails and establish steady connection state.
  connections.each { |connection| request(connection, PATH) }

  times = []
  failed = 0

  elapsed = Benchmark.realtime do
    remaining = REQUESTS

    while remaining.positive?
      batch = []

      connections.each do |connection|
        STREAMS.times do
          break if batch.length >= remaining

          batch << [Benchmarks.now, start_request(connection, PATH)]
        end
      end

      batch.each do |started_at, pending_request|
        finish_request(pending_request)&.status == 200 ? times << (Benchmarks.now - started_at) : failed += 1
      rescue StandardError
        failed += 1
      end

      remaining -= batch.length
    end
  end

  Benchmarks::Result.new(
    requests: REQUESTS,
    connections: CONNECTIONS,
    streams: STREAMS,
    times: times,
    failed: failed,
    elapsed: elapsed,
  )
ensure
  connections&.each { |connection| connection.disconnect rescue nil }
end

begin
  server, thread = start_server
  Benchmarks.print_result("Quicsilver Rails baseline", measure, path: PATH, workers: WORKERS)
ensure
  stop_server(server, thread)
end
