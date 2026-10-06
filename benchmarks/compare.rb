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
  # IMPAIR_PATH points at a checkout, for running the benchmark against a
  # relay change before it is pushed.
  if (impair_path = ENV["IMPAIR_PATH"])
    gem "impair", path: impair_path
  else
    gem "impair", github: "hahmed/impair"
  end
end

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "async"
require "async/http"
require "async/http/endpoint"
require "falcon"
require "falcon/endpoint"
require "localhost/authority"
require "puma"
require "puma/configuration"
require "puma/launcher"
require "quicsilver"
require_relative "helpers"

REQUESTS = Integer(ENV.fetch("REQUESTS", "2000"))
CONCURRENCY = Integer(ENV.fetch("CONCURRENCY", "10"))
# How many transport connections each arm spreads its CONCURRENCY requests
# over. Browsers open six TCP connections to an origin and one QUIC
# connection, so the defaults are the browser shape: HTTP/1.1 on 6, HTTP/2
# and HTTP/3 on 1. Setting CONNECTIONS applies the same count to every arm,
# which is the other fair comparison.
RETRIES = Integer(ENV.fetch("RETRIES", "0"))
CONNECTIONS = {
  "HTTP/1.1" => Integer(ENV.fetch("CONNECTIONS", ENV.fetch("H1_CONNECTIONS", "6"))),
  "HTTP/2" => Integer(ENV.fetch("CONNECTIONS", ENV.fetch("H2_CONNECTIONS", "1"))),
  "HTTP/3" => Integer(ENV.fetch("CONNECTIONS", ENV.fetch("H3_CONNECTIONS", "1"))),
}.freeze
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

# "localhost" resolves to ["::1", "127.0.0.1"] on macOS and the other order
# elsewhere, so a server bound to one family and a client dialling the name is
# a coin toss. Bind and dial the same literal. ::1 by default because the
# client prefers it; loss.rb overrides both so Puma, which binds v4 only, is
# on the same path as the other two.
QUIC_ADDRESS = ENV.fetch("QUIC_ADDRESS", "::1")

def with_quicsilver(port)
  config = Quicsilver::Transport::Configuration.new(
    AUTHORITY.certificate_path, AUTHORITY.key_path
  )
  server = Quicsilver::Server.new(port, address: QUIC_ADDRESS, app: APP, server_configuration: config)
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
  # CONNECTIONS["HTTP/3"] QUIC connections, each carrying a share of the
  # CONCURRENCY streams. Dialling a literal means the certificate's
  # "localhost" no longer matches the name, so the name check goes off. The
  # TCP arms already run VERIFY_NONE in client_context, so this matches them
  # rather than conceding anything.
  clients = Array.new(CONNECTIONS["HTTP/3"]) do
    Quicsilver::Client.new(QUIC_ADDRESS, port, request_timeout: 30, unsecure: true).tap { |c| c.get(PATH) }
  end

  started = Benchmarks.now
  Benchmarks.distribute(REQUESTS, CONCURRENCY).each_with_index.map do |count, index|
    client = clients[index % clients.length]
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

  clients.each(&:disconnect)
  Result.new(server: "quicsilver", protocol: "HTTP/3", times: times, failed: failed, elapsed: elapsed)
end

# === Falcon, HTTP/2, and Puma, HTTP/1.1 ===
#
# Both over TLS with the same certificate, so the comparison is not encrypted
# against cleartext. async-http negotiates h2 with Falcon and http/1.1 with
# Puma via ALPN, so the protocol difference comes from the server.

def with_falcon(port)
  # Falcon::Endpoint, not Async::HTTP::Endpoint with the bare localhost
  # context: the bare context has no alpn_select_cb, so the server never
  # agreed to h2 even when offered it, and every "HTTP/2" row before this
  # was HTTP/1.1. Falcon's own endpoint installs the callback.
  endpoint = Falcon::Endpoint.parse("https://localhost:#{port}")
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
    wire = wire_protocol_for(protocol)
    endpoint = Async::HTTP::Endpoint.parse("https://#{host}:#{port}#{PATH}",
      protocol: wire, ssl_context: client_context(wire))
    # Each Async::HTTP::Client is a connection pool, and the pool grows to
    # meet demand: an HTTP/1.1 client with two requests in flight opens two
    # connections, and "six connections" would quietly become ten. limit: 1
    # makes a client one connection, so CONNECTIONS is what it says. HTTP/2
    # multiplexes its share of the streams over that one.
    # retries: 0, because async-http retries idempotent requests three times
    # by default, and a benchmark that silently re-sends a request after the
    # connection died reports the death as latency rather than as a failure.
    # A browser does retry, so RETRIES=3 is the realistic setting; 0 is the
    # one that shows what the transport did.
    clients = Array.new(CONNECTIONS[protocol]) { Async::HTTP::Client.new(endpoint, limit: 1, retries: RETRIES) }
    clients.first.get(PATH).finish
    assert_negotiated!(clients.first, protocol)

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

# A client context has to do two things, and the previous one did only the
# first. VERIFY_NONE, because the localhost certificate is self-signed and
# async-http's own default only skips verification when the host is spelled
# "localhost", not 127.0.0.1. And ALPN: passing any ssl_context replaces
# async-http's default, which is where alpn_protocols lived, so a context
# without it never offers h2 and the server falls back to HTTP/1.1. The falcon
# arm ran that way for every table before this was noticed, labelled HTTP/2
# the whole time.
def client_context(wire)
  context = OpenSSL::SSL::SSLContext.new
  context.verify_mode = OpenSSL::SSL::VERIFY_NONE
  context.alpn_protocols = wire.names
  context
end

# Pin the wire protocol to the arm's label rather than letting ALPN pick, so
# a server that only offers one cannot be measured under the other's name.
def wire_protocol_for(protocol)
  case protocol
  when "HTTP/2" then Async::HTTP::Protocol::HTTP2
  when "HTTP/1.1" then Async::HTTP::Protocol::HTTP11
  else raise ArgumentError, "unknown protocol #{protocol.inspect}"
  end
end

# The protocol column is a measurement, not a label. Looks at the connection
# the warm-up request actually used and refuses to continue under the wrong
# name. Reaches into the pool because async-http has no public accessor for
# it; if that breaks on an upgrade, this is the one place to fix.
def assert_negotiated!(client, protocol)
  pool = client.instance_variable_get(:@pool)
  connection = pool.instance_variable_get(:@resources).keys.first
  expected = (protocol == "HTTP/2") ? "HTTP2" : "HTTP1"
  actual = connection.class.name[/HTTP\d/]
  return if actual == expected

  raise "#{protocol} arm negotiated #{connection.class}: ALPN did not select the protocol being measured"
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

# IO.popen merges into the current environment rather than replacing it, and
# Bundler.original_env only reports what the shell already had. Variables
# Bundler *added* — BUNDLE_GEMFILE above all — would survive the merge, so map
# those to nil, which removes them.
CHILD_ENV = begin
  original = defined?(Bundler) ? Bundler.original_env.to_h : {}
  added = ENV.keys - original.keys
  original.merge(added.to_h { |key| [key, nil] }).freeze
end

def run_child(name)
  output = IO.popen(
    # The child re-runs this file and re-evaluates the inline gemfile, which
    # cannot activate falcon or puma while it inherits the parent's bundler
    # environment: GEM_HOME, GEM_PATH and RUBYOPT all point at the repo's own
    # gemspec-only Gemfile. Bundler.original_env is what the shell had before
    # setup, so the child resolves the inline gemfile the way a bare ruby would.
    CHILD_ENV.merge(
      "BENCH_ONE" => name, "REQUESTS" => REQUESTS.to_s, "CONCURRENCY" => CONCURRENCY.to_s,
      "WORKLOAD" => WORKLOAD, "RUNS" => "1"
    ),
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
