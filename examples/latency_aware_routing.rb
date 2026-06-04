#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 3: latency-aware routing as a separate policy from pressure.
#
#   bundle exec ruby examples/latency_aware_routing.rb
#
# worker-1 is intentionally slower, but it is not necessarily busy. A purely
# pressure-aware policy might still send it traffic when its queue is empty.
# This example tracks rolling request latency per worker and uses that history
# to reduce traffic to consistently slow endpoints.

require_relative "example_helper"
require "rbconfig"

$stdout.sync = true

HOST = "127.0.0.1"
WORKERS = Integer(ENV.fetch("WORKERS", "3"))
REQUESTS = Integer(ENV.fetch("REQUESTS", "24"))
CONCURRENCY = Integer(ENV.fetch("CONCURRENCY", "6"))
SLOW_WORKER_MS = Integer(ENV.fetch("SLOW_WORKER_MS", "250"))
WINDOW_SIZE = Integer(ENV.fetch("WINDOW_SIZE", "50"))

class RollingLatency
  def initialize(size: WINDOW_SIZE)
    @size = size
    @samples = []
    @mutex = Mutex.new
  end

  def record(duration_ms, status)
    @mutex.synchronize do
      @samples << { duration_ms: duration_ms, status: status }
      @samples.shift while @samples.size > @size
    end
  end

  def to_h
    samples = @mutex.synchronize { @samples.dup }
    durations = samples.map { |sample| sample[:duration_ms] }
    errors = samples.count { |sample| sample[:status].to_i >= 500 }

    {
      "count" => samples.size,
      "p50_ms" => percentile(durations, 50),
      "p95_ms" => percentile(durations, 95),
      "error_rate" => samples.empty? ? 0.0 : (errors.to_f / samples.size).round(3)
    }
  end

  private

  def percentile(values, percentile)
    return 0.0 if values.empty?

    sorted = values.sort
    index = ((percentile / 100.0) * (sorted.size - 1)).round
    sorted[index].round(1)
  end
end

class LatencySignal
  def self.for(stats)
    new(stats || {})
  end

  def initialize(stats)
    @stats = stats || {}
  end

  def score(local_inflight: 0)
    p95_ms + (error_rate * 1_000) + (local_inflight * 50)
  end

  def to_h
    {
      "p95_ms" => p95_ms,
      "error_rate" => error_rate,
      "score" => score.round(1),
      "reason" => reason
    }
  end

  private

  def p95_ms
    @stats.dig("latency", "p95_ms").to_f
  end

  def error_rate
    @stats.dig("latency", "error_rate").to_f
  end

  def reason
    if @stats.empty?
      "stats_unavailable"
    elsif error_rate.positive?
      "errors"
    elsif p95_ms > 200
      "slow"
    else
      "ok"
    end
  end
end

Worker = Struct.new(:id, :host, :port, :pid, :delay_ms, keyword_init: true) do
  def health
    response = Quicsilver::Client.get(host, port, "/_quicsilver/health",
      unsecure: true, request_timeout: 1, connection_timeout: 500)
    JSON.parse(response.body)
  rescue JSON::ParserError, Quicsilver::Error, SystemCallError
    {}
  end

  def ready?
    response = Quicsilver::Client.get(host, port, "/_quicsilver/ready",
      unsecure: true, request_timeout: 1, connection_timeout: 500)
    response.status == 200
  rescue Quicsilver::Error, SystemCallError
    false
  end

  def get(path)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = Quicsilver::Client.get(host, port, path, unsecure: true, request_timeout: 5)
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)

    { worker_id: id, status: response.status, duration_ms: duration_ms }
  rescue => error
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)
    { worker_id: id, status: nil, duration_ms: duration_ms, error: "#{error.class}: #{error.message}" }
  end
end

class ToyLoadBalancer
  def initialize(workers, strategy:)
    @workers = workers
    @strategy = strategy
    @index = 0
    @inflight = Hash.new(0)
    @routed = Hash.new(0)
    @mutex = Mutex.new
  end

  def get(path)
    worker = checkout_worker
    worker.get(path)
  ensure
    checkin_worker(worker) if worker
  end

  private

  def checkout_worker
    @mutex.synchronize do
      worker = choose_worker
      @inflight[worker.id] += 1
      @routed[worker.id] += 1
      worker
    end
  end

  def choose_worker
    case @strategy
    when :round_robin
      round_robin_worker
    when :latency_aware
      latency_aware_worker
    else
      raise ArgumentError, "unknown strategy: #{@strategy.inspect}"
    end
  end

  def round_robin_worker
    worker = @workers[@index % @workers.size]
    @index += 1
    worker
  end

  def latency_aware_worker
    # Keep a tiny probe floor. Production outlier policies usually keep probing
    # reduced-weight endpoints so they can recover instead of disappearing forever.
    if (unprobed = @workers.find { |worker| @routed[worker.id].zero? })
      return unprobed
    end

    scored = @workers.map do |worker|
      signal = LatencySignal.for(worker.health)
      [worker, signal.score(local_inflight: @inflight[worker.id])]
    end
    lowest = scored.map(&:last).min
    scored.find { |_, score| score == lowest }.first
  end

  def checkin_worker(worker)
    @mutex.synchronize { @inflight[worker.id] -= 1 }
  end
end

def run_worker!
  Quicsilver.logger = Logger.new(File::NULL)

  worker_id = ENV.fetch("WORKER_ID")
  port = Integer(ENV.fetch("PORT"))
  delay_ms = Integer(ENV.fetch("DELAY_MS", "0"))
  latency = RollingLatency.new

  app = ->(env) {
    case env["PATH_INFO"]
    when "/_quicsilver/ready"
      Example.json_response(200, "ready" => true, "worker_id" => worker_id)
    when "/_quicsilver/health"
      stats = latency.to_h
      Example.json_response(200, stats.merge("latency" => stats, "signal" => LatencySignal.for("latency" => stats).to_h))
    when "/hello"
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status = 200
      sleep delay_ms / 1000.0 if delay_ms.positive?
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)
      latency.record(duration_ms, status)
      Example.text_response(status, "hello from #{worker_id}\n")
    else
      Example.text_response(404, "not found\n")
    end
  }

  server = Quicsilver::Server.new(port, app: app, server_configuration: EXAMPLE_TLS_CONFIG)

  trap("TERM") do
    server.stop rescue nil
    exit
  end

  server.start
ensure
  server&.stop rescue nil
end

def spawn_worker(index)
  id = "worker-#{index + 1}"
  delay_ms = index.zero? ? SLOW_WORKER_MS : 0
  port = Example.available_udp_port(HOST)
  env = {
    "QUICSILVER_LATENCY_WORKER" => "1",
    "WORKER_ID" => id,
    "PORT" => port.to_s,
    "DELAY_MS" => delay_ms.to_s
  }

  pid = Process.spawn(env, RbConfig.ruby, __FILE__)
  worker = Worker.new(id: id, host: HOST, port: port, pid: pid, delay_ms: delay_ms)

  Example.wait_until { worker.ready? }
  worker
end

def warm_up(workers)
  Example.heading "Warm up latency history"
  workers.each do |worker|
    3.times { worker.get("/hello") }
    health = worker.health
    Example.detail worker.id, "delay=#{worker.delay_ms}ms p95=#{health.dig('latency', 'p95_ms')}ms"
  end
end

def run_phase(title, strategy, workers)
  Example.heading title

  lb = ToyLoadBalancer.new(workers, strategy: strategy)
  queue = Queue.new
  REQUESTS.times { queue << "/hello" }

  results = []
  results_mutex = Mutex.new

  started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  threads = CONCURRENCY.times.map do
    Thread.new do
      loop do
        path = queue.pop(true) rescue nil
        break unless path

        result = lb.get(path)
        results_mutex.synchronize { results << result }
      end
    end
  end
  threads.each(&:join)
  elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round(1)

  print_summary(workers, results, elapsed_ms)
end

def percentile(values, percentile)
  return 0 if values.empty?

  sorted = values.sort
  index = ((percentile / 100.0) * (sorted.size - 1)).round
  sorted[index]
end

def print_summary(workers, results, elapsed_ms)
  durations = results.map { |result| result[:duration_ms] }

  Example.detail "elapsed", "#{elapsed_ms}ms"
  Example.detail "latency", "p50=#{percentile(durations, 50)}ms p95=#{percentile(durations, 95)}ms"

  puts
  puts format("  %-8s %6s %8s %9s %9s %10s", "worker", "delay", "requests", "p50", "p95", "health_p95")
  puts "  #{'-' * 67}"

  request_counts = {}
  workers.each do |worker|
    worker_results = results.select { |result| result[:worker_id] == worker.id }
    worker_durations = worker_results.map { |result| result[:duration_ms] }
    health = worker.health
    request_counts[worker.id] = worker_results.size

    puts format(
      "  %-8s %5dms %8d %8.1fms %8.1fms %9.1fms",
      worker.id,
      worker.delay_ms,
      worker_results.size,
      percentile(worker_durations, 50),
      percentile(worker_durations, 95),
      health.dig("latency", "p95_ms").to_f
    )
  end

  { p95: percentile(durations, 95), request_counts: request_counts }
end

if ENV["QUICSILVER_LATENCY_WORKER"] == "1"
  run_worker!
  exit
end

workers = []

begin
  Example.heading "Latency-aware Routing Demo", level: 1
  Example.detail "scenario", "worker-1 is consistently slow"
  Example.detail "workers", WORKERS
  Example.detail "requests", REQUESTS
  Example.detail "concurrency", CONCURRENCY
  Example.detail "slow worker", "worker-1 sleeps #{SLOW_WORKER_MS}ms per request"
  Example.detail "signal flow", "rolling latency -> LatencySignal -> routing"

  Example.heading "Starting workers"
  workers = WORKERS.times.map { |index| spawn_worker(index) }
  workers.each do |worker|
    Example.detail worker.id, "https://#{worker.host}:#{worker.port} delay=#{worker.delay_ms}ms pid=#{worker.pid}"
  end

  warm_up(workers)

  round_robin = run_phase("1. Round robin", :round_robin, workers)

  Quicsilver::Client.close_pool
  sleep 0.2

  latency_aware = run_phase("2. Latency aware", :latency_aware, workers)

  slow_worker = workers.first.id

  Example.heading "What to notice"
  puts "  Slow-worker requests: #{round_robin[:request_counts][slow_worker]} -> #{latency_aware[:request_counts][slow_worker]}"
  puts "  Fleet p95 latency:     #{round_robin[:p95]}ms -> #{latency_aware[:p95]}ms"
  puts
  puts "  This is latency-aware routing. It reduces traffic to an endpoint that is"
  puts "  historically slow, even when that endpoint is not currently full. The one"
  puts "  remaining request is a probe so the endpoint has a path to recovery."
  puts "  Combine this with pressure-aware routing when you want both capacity and health."
ensure
  Quicsilver::Client.close_pool rescue nil
  workers.each do |worker|
    Process.kill("TERM", worker.pid) rescue nil
    Process.wait(worker.pid) rescue nil
  end
end
