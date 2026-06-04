#!/usr/bin/env ruby
# frozen_string_literal: true

# Example 2: propagate one app-server load signal to a toy load balancer.
#
#   bundle exec ruby examples/worker_load_balancing.rb
#
# This is the follow-up to lifecycle_drain.rb. Each worker exposes ordinary
# HTTP endpoints:
#
#   /_quicsilver/ready
#   /_quicsilver/stats
#
# The toy LB polls those endpoints and compares round-robin routing with a
# least-loaded policy. To make the signal visible, worker-1 is intentionally
# slower than the other workers.

require_relative "example_helper"
require "rbconfig"

$stdout.sync = true

HOST = "127.0.0.1"
WORKERS = Integer(ENV.fetch("WORKERS", "3"))
WORKER_THREADS = Integer(ENV.fetch("WORKER_THREADS", "2"))
MAX_QUEUE_SIZE = Integer(ENV.fetch("MAX_QUEUE_SIZE", (WORKER_THREADS * 4).to_s))
REQUESTS = Integer(ENV.fetch("REQUESTS", "36"))
CONCURRENCY = Integer(ENV.fetch("CONCURRENCY", "9"))
HOT_WORKER_MS = Integer(ENV.fetch("HOT_WORKER_MS", "250"))
UNREADY_PRESSURE = Float(ENV.fetch("UNREADY_PRESSURE", "0.85"))

class LoadSignal
  def self.for(stats)
    new(stats || {})
  end

  def initialize(stats)
    @stats = stats || {}
  end

  def ready?
    running? && !draining? && !queue_full? && pressure < UNREADY_PRESSURE
  end

  def accepting_requests?
    ready?
  end

  def pressure(local_inflight: 0)
    if @stats.empty?
      1.0
    else
      [request_pressure(local_inflight: local_inflight), queue_pressure].max.clamp(0.0, 1.0)
    end
  end

  def to_h
    {
      "ready" => ready?,
      "accepting_requests" => accepting_requests?,
      "pressure" => pressure.round(3),
      "reason" => reason,
      "components" => {
        "requests" => request_pressure.round(3),
        "queue" => queue_pressure.round(3)
      }
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

    def reason
      if @stats.empty?
        "stats_unavailable"
      elsif !running?
        "not_running"
      elsif draining?
        "draining"
      elsif queue_full?
        "queue_full"
      elsif pressure >= UNREADY_PRESSURE
        "high_pressure"
      else
        "ok"
      end
    end

    def request_pressure(local_inflight: 0)
      active = @stats.dig("requests", "active").to_f + local_inflight.to_f
      threads = @stats.dig("scheduler", "threads").to_f
      ratio(active, threads)
    end

    def queue_pressure
      pending = @stats.dig("scheduler", "pending").to_f
      max = @stats.dig("scheduler", "max_queue_size").to_f
      ratio(pending, max)
    end

    def ratio(numerator, denominator)
      denominator.positive? ? numerator / denominator : 0.0
    end
end

Worker = Struct.new(:id, :host, :port, :pid, :delay_ms, keyword_init: true) do
  def stats
    response = Quicsilver::Client.get(host, port, "/_quicsilver/stats",
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
    @mutex = Mutex.new
  end

  def get(path)
    worker = choose_worker
    track_start(worker)
    worker.get(path)
  ensure
    track_finish(worker) if worker
  end

  private
    def choose_worker
      case @strategy
      when :round_robin
        round_robin_worker
      when :least_loaded
        least_loaded_worker
      else
        raise ArgumentError, "unknown strategy: #{@strategy.inspect}"
      end
    end

    def round_robin_worker
      @mutex.synchronize do
        worker = @workers[@index % @workers.size]
        @index += 1
        worker
      end
    end

    def least_loaded_worker
      scored = @workers.map do |worker|
        signal = LoadSignal.for(worker.stats)
        [worker, signal.pressure(local_inflight: inflight_for(worker))]
      end
      lowest = scored.map(&:last).min
      candidates = scored.select { |_, score| score == lowest }.map(&:first)

      @mutex.synchronize do
        worker = candidates[@index % candidates.size]
        @index += 1
        worker
      end
    end

    def track_start(worker)
      @mutex.synchronize { @inflight[worker.id] += 1 }
    end

    def track_finish(worker)
      @mutex.synchronize { @inflight[worker.id] -= 1 }
    end

    def inflight_for(worker)
      @mutex.synchronize { @inflight[worker.id] }
    end
end

def worker_stats(server, worker_id, port, delay_ms, control_request: false)
  stats = server.stats

  if control_request
    active = stats.dig("requests", "active").to_i
    stats["requests"] = stats["requests"].merge("active" => [active - 1, 0].max)
  end

  stats.merge(
    "worker" => { "id" => worker_id, "pid" => Process.pid, "port" => port, "delay_ms" => delay_ms },
    "load_signal" => LoadSignal.for(stats).to_h
  )
end

def worker_signal(server, worker_id, port, delay_ms)
  LoadSignal.for(worker_stats(server, worker_id, port, delay_ms, control_request: true))
end

def run_worker!
  Quicsilver.logger = Logger.new(File::NULL)

  worker_id = ENV.fetch("WORKER_ID")
  port = Integer(ENV.fetch("PORT"))
  delay_ms = Integer(ENV.fetch("DELAY_MS", "0"))
  server = nil

  app = ->(env) {
    signal = worker_signal(server, worker_id, port, delay_ms)

    case env["PATH_INFO"]
    when "/_quicsilver/ready"
      Example.json_response(signal.ready? ? 200 : 503, signal.to_h.merge("worker_id" => worker_id))
    when "/_quicsilver/stats"
      Example.json_response(200, worker_stats(server, worker_id, port, delay_ms, control_request: true))
    when "/hello"
      if signal.accepting_requests?
        sleep delay_ms / 1000.0 if delay_ms.positive?
        Example.text_response(200, "hello from #{worker_id}\n")
      else
        Example.json_response(503, "error" => "worker overloaded", "load_signal" => signal.to_h)
      end
    else
      Example.text_response(404, "not found\n")
    end
  }

  server = Quicsilver::Server.new(
    port,
    app: app,
    server_configuration: EXAMPLE_TLS_CONFIG,
    threads: WORKER_THREADS,
    max_queue_size: MAX_QUEUE_SIZE
  )

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
  delay_ms = index.zero? ? HOT_WORKER_MS : 0
  port = Example.available_udp_port(HOST)
  env = {
    "QUICSILVER_TOY_LB_WORKER" => "1",
    "WORKER_ID" => id,
    "PORT" => port.to_s,
    "DELAY_MS" => delay_ms.to_s,
    "WORKER_THREADS" => WORKER_THREADS.to_s,
    "MAX_QUEUE_SIZE" => MAX_QUEUE_SIZE.to_s,
    "UNREADY_PRESSURE" => UNREADY_PRESSURE.to_s
  }

  pid = Process.spawn(env, RbConfig.ruby, __FILE__)
  worker = Worker.new(id: id, host: HOST, port: port, pid: pid, delay_ms: delay_ms)

  Example.wait_until { worker.ready? }
  worker
end

def run_phase(title, strategy, workers)
  Example.heading title

  lb = ToyLoadBalancer.new(workers, strategy: strategy)
  queue = Queue.new
  REQUESTS.times { queue << "/hello" }

  results = []
  results_mutex = Mutex.new
  max_pressure = Hash.new(0.0)
  monitor_done = false

  monitor = Thread.new do
    until monitor_done
      workers.each do |worker|
        pressure = worker.stats.dig("load_signal", "pressure").to_f
        max_pressure[worker.id] = [max_pressure[worker.id], pressure].max
      end
      sleep 0.025
    end
  end

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

  monitor_done = true
  monitor.join

  print_phase_summary(workers, results, max_pressure, elapsed_ms)
end

def percentile(values, percentile)
  return 0 if values.empty?

  sorted = values.sort
  index = ((percentile / 100.0) * (sorted.size - 1)).round
  sorted[index]
end

def print_phase_summary(workers, results, max_pressure, elapsed_ms)
  durations = results.map { |result| result[:duration_ms] }
  errors = results.count { |result| result[:error] || result[:status].to_i >= 500 }

  Example.detail "elapsed", "#{elapsed_ms}ms"
  Example.detail "latency", "p50=#{percentile(durations, 50)}ms p95=#{percentile(durations, 95)}ms"
  Example.detail "errors", errors

  puts
  puts format("  %-8s %6s %8s %12s %9s %9s", "worker", "delay", "requests", "max_pressure", "p50", "p95")
  puts "  #{'-' * 66}"

  request_counts = {}

  workers.each do |worker|
    worker_results = results.select { |result| result[:worker_id] == worker.id }
    worker_durations = worker_results.map { |result| result[:duration_ms] }
    request_counts[worker.id] = worker_results.size

    puts format(
      "  %-8s %5dms %8d %12.2f %8.1fms %8.1fms",
      worker.id,
      worker.delay_ms,
      worker_results.size,
      max_pressure[worker.id],
      percentile(worker_durations, 50),
      percentile(worker_durations, 95)
    )
  end

  { p95: percentile(durations, 95), errors: errors, request_counts: request_counts }
end

if ENV["QUICSILVER_TOY_LB_WORKER"] == "1"
  run_worker!
  exit
end

workers = []

begin
  Example.heading "Worker-aware Load Signal Demo", level: 1
  Example.detail "scenario", "worker-1 is intentionally slow"
  Example.detail "workers", WORKERS
  Example.detail "worker threads", WORKER_THREADS
  Example.detail "requests", REQUESTS
  Example.detail "concurrency", CONCURRENCY
  Example.detail "slow worker", "worker-1 sleeps #{HOT_WORKER_MS}ms per request"
  Example.detail "signal flow", "Server#stats -> LoadSignal -> routing + readiness"

  Example.heading "Starting workers"
  workers = WORKERS.times.map { |index| spawn_worker(index) }
  workers.each do |worker|
    Example.detail worker.id, "https://#{worker.host}:#{worker.port} delay=#{worker.delay_ms}ms pid=#{worker.pid}"
  end

  round_robin = run_phase("1. Round robin", :round_robin, workers)

  Quicsilver::Client.close_pool
  sleep 0.2

  least_loaded = run_phase("2. Least loaded", :least_loaded, workers)

  slow_worker = workers.first.id

  Example.heading "What to notice"
  puts "  Slow-worker requests: #{round_robin[:request_counts][slow_worker]} -> #{least_loaded[:request_counts][slow_worker]}"
  puts "  Fleet p95 latency:     #{round_robin[:p95]}ms -> #{least_loaded[:p95]}ms"
  puts "  Errors:                #{round_robin[:errors]} -> #{least_loaded[:errors]}"
  puts
  puts "  This is pressure-aware routing, not outlier detection. It notices when an"
  puts "  endpoint is busy right now. A slow endpoint can still receive traffic when"
  puts "  it has spare request capacity."
ensure
  Quicsilver::Client.close_pool rescue nil
  workers.each do |worker|
    Process.kill("TERM", worker.pid) rescue nil
    Process.wait(worker.pid) rescue nil
  end
end
