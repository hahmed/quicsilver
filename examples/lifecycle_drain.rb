#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 1: graceful drain as an HTTP/3 lifecycle control loop.
#
#   bundle exec ruby examples/lifecycle_drain.rb
#
# This keeps the policy deliberately small and in one file:
#
#   Quicsilver::Server#stats -> LifecycleSignal -> readiness / drain / safe-to-exit
#
# A real quicsilver-health/quicsilver-lifecycle package could extract the
# LifecycleSignal, but the core idea should stay this boring:
#
#   1. fail readiness
#   2. send HTTP/3 GOAWAY via Server#shutdown
#   3. refuse/avoid new work
#   4. finish in-flight streams
#   5. exit when active work reaches zero or the deadline expires

require_relative "example_helper"

$stdout.sync = true

HOST = ENV.fetch("HOST", "127.0.0.1")
PORT = Integer(ENV.fetch("PORT", "0"))
SLOW_REQUESTS = Integer(ENV.fetch("SLOW_REQUESTS", "3"))
SLOW_MS = Integer(ENV.fetch("SLOW_MS", "2_000"))
SHUTDOWN_TIMEOUT = Integer(ENV.fetch("SHUTDOWN_TIMEOUT", "10"))

class LifecycleSignal
  def self.for(server)
    new(server&.stats || {})
  end

  def initialize(stats)
    @stats = stats || {}
  end

  def ready?
    running? && !draining? && !queue_full?
  end

  def accepting_requests?
    ready?
  end

  def safe_to_exit?
    draining? && active_requests.zero? && pending_requests.zero?
  end

  def state
    if !running?
      "stopped"
    elsif draining?
      safe_to_exit? ? "drained" : "draining"
    elsif queue_full?
      "overloaded"
    else
      "ready"
    end
  end

  def to_h
    {
      "state" => state,
      "ready" => ready?,
      "accepting_requests" => accepting_requests?,
      "safe_to_exit" => safe_to_exit?,
      "active_connections" => active_connections,
      "active_requests" => active_requests,
      "pending_requests" => pending_requests,
      "queue_max" => @stats.dig("scheduler", "max_queue_size"),
      "goaway_or_drain" => draining?
    }
  end

  private
    def running?
      @stats["running"] == true
    end

    def draining?
      @stats["shutting_down"] == true
    end

    def queue_full?
      @stats.dig("scheduler", "full") == true
    end

    def active_connections
      @stats.dig("connections", "active").to_i
    end

    def active_requests
      @stats.dig("requests", "active").to_i
    end

    def pending_requests
      if running? || draining?
        @stats.dig("scheduler", "pending").to_i
      else
        0
      end
    end
end

def banner(title)
  Example.heading(title, level: 1)
end

def section(number, title)
  Example.heading("#{number}. #{title}")
end

def yes_no(value)
  value ? "yes" : "no"
end

def lifecycle_header
  Example.say
  Example.say format(
    "  %-22s %-10s %-5s %-7s %-5s %5s %6s %5s",
    "sample", "state", "ready", "accept", "safe", "conns", "active", "queue"
  )
  Example.say "  #{'-' * 75}"
end

def lifecycle_row(label, server)
  data = LifecycleSignal.for(server).to_h

  Example.say format(
    "  %-22s %-10s %-5s %-7s %-5s %5d %6d %5d",
    label,
    data["state"],
    yes_no(data["ready"]),
    yes_no(data["accepting_requests"]),
    yes_no(data["safe_to_exit"]),
    data["active_connections"],
    data["active_requests"],
    data["pending_requests"]
  )
end

def elapsed_label(started_at)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
  "t+#{format('%.1f', elapsed)}s"
end

def attempt_new_request(client)
  response = client.get("/hello", timeout: 2)
  "#{response.status} #{response.body.inspect}"
rescue => error
  "#{error.class}: #{error.message}"
end

Quicsilver.logger = Logger.new(File::NULL)

port = PORT.zero? ? Example.available_udp_port(HOST) : PORT
server = nil

app = ->(env) {
  signal = LifecycleSignal.for(server)

  case env["PATH_INFO"]
  when "/_quicsilver/ready"
    Example.json_response(signal.ready? ? 200 : 503, signal.to_h)
  when "/_quicsilver/lifecycle"
    Example.json_response(200, signal.to_h)
  when %r{\A/slow/(\d+)}
    request_id = Regexp.last_match(1)
    sleep SLOW_MS / 1000.0
    Example.text_response(200, "slow request #{request_id} completed while #{signal.state}\n")
  when "/hello"
    if signal.accepting_requests?
      Example.text_response(200, "hello before drain\n")
    else
      Example.json_response(503, "error" => "server draining", "lifecycle" => signal.to_h)
    end
  else
    Example.text_response(404, "not found\n")
  end
}

server = Quicsilver::Server.new(
  port,
  app: app,
  server_configuration: EXAMPLE_TLS_CONFIG,
  threads: SLOW_REQUESTS + 2
)
server_thread = Thread.new { server.start }
client = Quicsilver::Client.new(HOST, port, unsecure: true)
shutdown_thread = nil
monitor = nil
slow_threads = []
monitor_done = false

begin
  Example.wait_until { server.running? }

  banner "HTTP/3 Lifecycle Drain Demo"
  Example.detail "server", "https://#{HOST}:#{port}"
  Example.detail "slow streams", "#{SLOW_REQUESTS} × #{SLOW_MS}ms"
  Example.detail "shutdown timeout", "#{SHUTDOWN_TIMEOUT}s"
  Example.detail "control loop", "readiness=false -> GOAWAY/drain -> active=0 -> safe exit"

  section 1, "Warm up the connection"
  Example.detail "GET /hello", attempt_new_request(client)
  lifecycle_header
  lifecycle_row "before drain", server

  section 2, "Start long-running streams"
  slow_threads = SLOW_REQUESTS.times.map do |index|
    Thread.new do
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = client.get("/slow/#{index + 1}", timeout: SHUTDOWN_TIMEOUT + 5)
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)
      Example.say format("  stream #%-2d completed   status=%d   elapsed=%7.1fms", index + 1, response.status, elapsed_ms)
    rescue => error
      Example.say format("  stream #%-2d failed      %s: %s", index + 1, error.class, error.message)
    end
  end

  Example.wait_until { server.stats.dig("requests", "active") >= SLOW_REQUESTS }
  lifecycle_header
  lifecycle_row "streams in flight", server

  section 3, "Begin drain"
  Example.detail "action", "Server#shutdown(timeout: #{SHUTDOWN_TIMEOUT})"
  shutdown_thread = Thread.new { server.shutdown(timeout: SHUTDOWN_TIMEOUT) }
  Example.wait_until { server.shutting_down }
  sleep 0.05 # give GOAWAY/readiness state a moment to propagate, but keep streams in flight

  Example.detail "readiness", "not ready"
  Example.detail "routing", "new work should move to other endpoints"
  Example.detail "in-flight", "existing streams continue until complete"
  lifecycle_header
  lifecycle_row "after GOAWAY", server

  monitor_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  monitor = Thread.new do
    until monitor_done
      lifecycle_row elapsed_label(monitor_started_at), server
      sleep 0.5
    end
  end

  slow_threads.each(&:join)
  shutdown_thread.join
  monitor_done = true
  monitor.join

  section 4, "Shutdown complete"
  lifecycle_header
  lifecycle_row "after shutdown", server
  Example.detail "takeaway", "routing changes immediately; in-flight HTTP/3 streams drain cleanly"
ensure
  monitor_done = true
  monitor&.join(1)
  client&.disconnect rescue nil
  Quicsilver::Client.close_pool rescue nil
  server&.stop if server&.running? rescue nil
  server_thread&.join(2)
end
