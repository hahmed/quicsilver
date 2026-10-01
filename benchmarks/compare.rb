#!/usr/bin/env ruby
# frozen_string_literal: true

# Quicsilver vs Puma vs Falcon, same Rack app, default configuration.
#
# This is the local-development number and nothing more. Every advantage HTTP/3
# has needs a condition localhost does not provide: 0-RTT needs a round trip to
# save, and no head-of-line blocking needs a lost or reordered packet. Loopback
# has neither. Expect HTTP/1.1 to win here, and read the caveats printed with
# the results before quoting any of it.
#
#   ruby benchmarks/compare.rb
#   REQUESTS=2000 CONCURRENCY=10 ruby benchmarks/compare.rb
#   SERVERS=quicsilver,falcon ruby benchmarks/compare.rb
#
# Known unexplained variance: Quicsilver's throughput has measured anywhere
# from 2700 to 8900 req/s for the same code, same machine, isolated processes,
# while Falcon and Puma stayed within a few percent across the same shells. Do
# not quote a single figure from here until that is understood. Falcon and Puma
# comparisons are stable; the HTTP/3 number is not yet.
#
# CONCURRENCY is requests in flight, which each protocol reaches differently:
# HTTP/3 and HTTP/2 open that many streams on one connection, HTTP/1.1 opens
# that many connections, because it has no streams. That is the comparison, not
# a flaw in it.
#
# Defaults are what each server ships with, not matched capacity. Quicsilver
# advertises a stream limit of threads + queue and makes extra streams wait;
# Puma queues in the kernel backlog, default 1024; Falcon spawns a fiber per
# request. Those are three different answers to overload, and at high
# concurrency they matter more than the protocol.

require "bundler/inline"

gemfile do
  source "https://rubygems.org"
  gem "rails"
  gem "localhost"
  gem "falcon"
  gem "puma"
  gem "protocol-http"
  gem "async-http"
  # The impairment relay used by latency.rb and loss.rb. Benchmark-only: it is
  # not a dependency of the library or of the app, so it lives here rather than
  # in the Gemfile.
  gem "impair", github: "hahmed/impair"
end

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "async"
require "async/http"
require "async/http/endpoint"
require "localhost/authority"
require "puma"
require "puma/configuration"
require "puma/launcher"
require "quicsilver"
require_relative "helpers"

REQUESTS = Integer(ENV.fetch("REQUESTS", "2000"))
CONCURRENCY = Integer(ENV.fetch("CONCURRENCY", "10"))
WORKLOAD = ENV.fetch("WORKLOAD", "tiny")
PATH = Benchmarks.path_for(WORKLOAD)
SERVERS = ENV.fetch("SERVERS", "quicsilver,falcon,puma").split(",").map(&:strip)
RUNS = Integer(ENV.fetch("RUNS", "3"))
AUTHORITY = Localhost::Authority.fetch

# One plain Rack app. No framework, so the app contributes as little as
# possible: a framework would be measured three times and tell us nothing about
# the servers.
BODIES = {
  "/" => Benchmarks::TINY_RESPONSE,
  "/hello" => Benchmarks::HELLO_RESPONSE,
  "/small" => Benchmarks::SMALL_RESPONSE,
  "/big" => Benchmarks::BIG_RESPONSE
}.freeze

APP = lambda do |env|
  body = BODIES.fetch(env["PATH_INFO"], Benchmarks::TINY_RESPONSE)
  [200, {"content-type" => "text/plain", "content-length" => body.bytesize.to_s}, [body]]
end

Result = Struct.new(:server, :protocol, :times, :failed, :elapsed, keyword_init: true) do
  def rps = times.length / elapsed
end

def free_port
  socket = UDPSocket.new
  socket.bind("127.0.0.1", 0)
  socket.addr[1]
ensure
  socket&.close
end

# === Quicsilver, HTTP/3 ===

def with_quicsilver(port)
  config = Quicsilver::Transport::Configuration.new(
    AUTHORITY.certificate_path, AUTHORITY.key_path
  )
  server = Quicsilver::Server.new(port, address: "::1", app: APP, server_configuration: config)
  Quicsilver::Server.instance = server
  thread = Thread.new { server.start }
  sleep 0.05 until server.running?
  yield
ensure
  server&.stop
  thread&.join(5)
end

def measure_quicsilver(port)
  times = []
  failed = 0
  mutex = Mutex.new
  # One connection carrying CONCURRENCY streams, which is the HTTP/3 shape.
  client = Quicsilver::Client.new("localhost", port, request_timeout: 30)
  client.get(PATH)

  started = Benchmarks.now
  Benchmarks.distribute(REQUESTS, CONCURRENCY).map do |count|
    Thread.new do
      count.times do
        at = Benchmarks.now
        response = client.get(PATH)
        elapsed = Benchmarks.now - at
        mutex.synchronize do
          response&.status == 200 ? times << elapsed : failed += 1
        end
      rescue StandardError
        mutex.synchronize { failed += 1 }
      end
    end
  end.each(&:join)
  elapsed = Benchmarks.now - started

  client.disconnect
  Result.new(server: "quicsilver", protocol: "HTTP/3", times: times, failed: failed, elapsed: elapsed)
end

# === Falcon, HTTP/2, and Puma, HTTP/1.1 ===
#
# Both over TLS with the same certificate, so the comparison is not encrypted
# against cleartext. async-http negotiates h2 with Falcon and http/1.1 with
# Puma via ALPN, so the protocol difference comes from the server.

def with_falcon(port)
  endpoint = Async::HTTP::Endpoint.parse(
    "https://localhost:#{port}",
    ssl_context: AUTHORITY.server_context
  )
  container = nil
  thread = Thread.new do
    Async do
      server = Falcon::Server.new(Falcon::Server.middleware(APP), endpoint)
      container = server
      server.run.wait
    end
  end
  sleep 0.3
  yield
ensure
  thread&.kill
  thread&.join(2)
end

def with_puma(port)
  config = Puma::Configuration.new do |c|
    c.ssl_bind "127.0.0.1", port, {
      cert: AUTHORITY.certificate_path, key: AUTHORITY.key_path, verify_mode: "none"
    }
    c.app APP
    c.log_requests false
    c.silence_single_worker_warning
  end
  launcher = Puma::Launcher.new(config, events: Puma::Events.new)
  thread = Thread.new { launcher.run }
  sleep 0.6
  yield
ensure
  launcher&.stop
  thread&.join(3)
end

def measure_async(name, protocol, port, host: "localhost")
  times = []
  failed = 0
  elapsed = nil

  Async do
    endpoint = Async::HTTP::Endpoint.parse("https://#{host}:#{port}#{PATH}", ssl_context: client_context)
    # HTTP/1.1 has no streams, so concurrency is connections. HTTP/2 multiplexes
    # CONCURRENCY streams over one.
    clients = (protocol == "HTTP/1.1") ? Array.new(CONCURRENCY) { Async::HTTP::Client.new(endpoint) } : [Async::HTTP::Client.new(endpoint)]
    clients.first.get(PATH).finish

    started = Benchmarks.now
    Benchmarks.distribute(REQUESTS, CONCURRENCY).each_with_index.map do |count, index|
      client = clients[index % clients.length]
      Async do
        count.times do
          at = Benchmarks.now
          response = client.get(PATH)
          response.finish
          took = Benchmarks.now - at
          response.status == 200 ? times << took : failed += 1
        rescue StandardError
          failed += 1
        end
      end
    end.each(&:wait)
    elapsed = Benchmarks.now - started
    clients.each(&:close)
  end

  Result.new(server: name, protocol: protocol, times: times, failed: failed, elapsed: elapsed)
end

def client_context
  context = OpenSSL::SSL::SSLContext.new
  context.verify_mode = OpenSSL::SSL::VERIFY_NONE
  context
end

# === Run ===

# Loadable as a harness: loss.rb reuses the server lifecycle and the
# measurement functions above.
# Each measurement runs in its own child process. Sharing one process makes
# the results depend on which server ran first: measured 8000 req/s for
# Quicsilver alone and 2000 for the same code after an earlier run in the same
# process, while Falcon and Puma were unaffected. A benchmark that can be
# contaminated by a previous measurement is not measuring the server.
#
# Spawned rather than forked, because macOS refuses to fork once threads have
# touched the Objective-C runtime.
def measure(name)
  port = free_port
  case name
  when "quicsilver" then with_quicsilver(port) { measure_quicsilver(port) }
  when "falcon" then with_falcon(port) { measure_async("falcon", "HTTP/2", port) }
  when "puma" then with_puma(port) { measure_async("puma", "HTTP/1.1", port, host: "127.0.0.1") }
  else warn "unknown server #{name.inspect}"
  end
end

def run_child(name)
  output = IO.popen(
    {"BENCH_ONE" => name, "REQUESTS" => REQUESTS.to_s, "CONCURRENCY" => CONCURRENCY.to_s,
     "WORKLOAD" => WORKLOAD, "RUNS" => "1"},
    [RbConfig.ruby, __FILE__], err: (ENV["DEBUG"] ? :out : File::NULL), &:read
  )
  warn output if ENV["DEBUG"] && !output.include?("RESULT\t")
  line = output.lines.find { |l| l.start_with?("RESULT\t") }
  return nil unless line

  _, server, protocol, rps, p50, p95, p99, failed = line.chomp.split("\t")
  {server: server, protocol: protocol, rps: rps.to_f, p50: p50.to_f,
   p95: p95.to_f, p99: p99.to_f, failed: failed.to_i}
end

# Child mode: measure one server and print a parseable line.
if (only = ENV["BENCH_ONE"])
  result = measure(only)
  if result
    s = Benchmarks.stats(result.times)
    puts format("RESULT\t%s\t%s\t%f\t%f\t%f\t%f\t%d",
      result.server, result.protocol, result.rps, s[:p50], s[:p95], s[:p99], result.failed)
  end
  exit 0
end

if __FILE__ == $PROGRAM_NAME

  puts "Quicsilver vs Puma vs Falcon — local development, default configuration"
  puts "#{REQUESTS} requests, #{CONCURRENCY} in flight, path #{PATH.inspect}, all over TLS"
  puts


  results = []

  SERVERS.each do |name|
    runs = RUNS.times.filter_map { run_child(name) }
    if runs.empty?
      warn "#{name}: no runs completed"
      next
    end

    median = runs.sort_by { |r| r[:rps] }[runs.length / 2]
    results << [median, runs.map { |r| r[:rps] }]
  end

  puts format("%-12s %-9s %9s %9s %9s %9s %8s %16s",
    "server", "protocol", "Req/s", "p50", "p95", "p99", "Failed", "Req/s range")
  puts "-" * 94
  results.each do |(result, rates)|
    puts format(
      "%-12s %-9s %9.0f %7.2fms %7.2fms %7.2fms %8d %16s",
      result[:server], result[:protocol], result[:rps], result[:p50], result[:p95], result[:p99],
      result[:failed],
      (rates.length > 1 ? format("%.0f-%.0f", rates.min, rates.max) : "single run")
    )
  end
end
