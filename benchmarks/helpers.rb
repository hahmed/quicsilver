# frozen_string_literal: true

require "logger"
require "socket"

module Benchmarks
  PATHS = {
    "tiny" => "/",
    "hello" => "/hello",
    "small" => "/small",
    "big" => "/big",
    "sleep" => "/sleep",
  }.freeze

  TINY_RESPONSE = "OK"
  HELLO_RESPONSE = "Hello World\n"
  SMALL_RESPONSE = ("Hello World\n" * 10) * 10
  BIG_RESPONSE = ("Hello World\n" * 1000) * 1000

  Result = Struct.new(:requests, :connections, :streams, :times, :failed, :elapsed, keyword_init: true) do
    def rps
      times.length / elapsed
    end
  end

  class << self
    attr_accessor :sleep_seconds

    def path_for(workload)
      PATHS.fetch(workload) { abort "unknown WORKLOAD=#{workload.inspect}; use #{PATHS.keys.join(", ")}" }
    end

    def rails_app(sleep_seconds: 0.1, secret_key_base: "benchmark")
      self.sleep_seconds = sleep_seconds
      require "rails"
      require "action_controller/railtie"

      initialize_rails_app(secret_key_base)
    end

    def random_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def distribute(total, buckets)
      base, extra = total.divmod(buckets)
      Array.new(buckets) { |index| base + (index < extra ? 1 : 0) }
    end

    def stats(times)
      return empty_stats if times.empty?

      sorted = times.sort
      n = sorted.size
      {
        count: n,
        avg: (times.sum / n * 1000).round(2),
        min: (sorted.first * 1000).round(2),
        max: (sorted.last * 1000).round(2),
        p50: percentile(sorted, 0.50),
        p95: percentile(sorted, 0.95),
        p99: percentile(sorted, 0.99),
      }
    end

    def print_result(title, result, path:, workers:)
      s = stats(result.times)

      puts "\n#{title}"
      puts "#{result.requests} requests, #{result.connections} connection(s), #{result.streams} stream(s) per connection, path #{path.inspect}"
      puts "workers: #{workers}"
      puts "-" * 76
      puts format("%9s %8s %8s %8s %8s %7s", "Req/s", "p50", "p95", "p99", "max", "Failed")
      puts "-" * 76
      puts format(
        "%9.0f %7.2fms %7.2fms %7.2fms %7.2fms %7d",
        result.rps,
        s[:p50],
        s[:p95],
        s[:p99],
        s[:max],
        result.failed,
      )
    end

    private
      def empty_stats
        { count: 0, avg: 0.0, min: 0.0, max: 0.0, p50: 0.0, p95: 0.0, p99: 0.0 }
      end

      def percentile(sorted_times, fraction)
        index = (sorted_times.length * fraction).floor.clamp(0, sorted_times.length - 1)
        (sorted_times[index] * 1000).round(2)
      end

      def initialize_rails_app(secret_key_base)
        return Application if const_defined?(:Application, false)

        controller = Class.new(ActionController::Base) do
          def index
            render plain: Benchmarks::TINY_RESPONSE
          end

          def hello
            render plain: Benchmarks::HELLO_RESPONSE
          end

          def small
            render plain: Benchmarks::SMALL_RESPONSE
          end

          def big
            render plain: Benchmarks::BIG_RESPONSE
          end

          def sleep
            Kernel.sleep(Benchmarks.sleep_seconds)
            render plain: Benchmarks::TINY_RESPONSE
          end
        end
        const_set(:BenchmarksController, controller)

        app = Class.new(Rails::Application) do
          config.root = __dir__
          config.consider_all_requests_local = true
          config.secret_key_base = secret_key_base
          config.eager_load = false
          config.enable_reloading = false
          config.reload_classes_only_on_change = false
          config.hosts.clear
          config.logger = Logger.new(File::NULL)
          config.public_file_server.enabled = false
          config.active_support.to_time_preserves_timezone = :zone

          routes.append do
            root to: "benchmarks/benchmarks#index"
            get "/hello", to: "benchmarks/benchmarks#hello"
            get "/small", to: "benchmarks/benchmarks#small"
            get "/big", to: "benchmarks/benchmarks#big"
            get "/sleep", to: "benchmarks/benchmarks#sleep"
          end
        end
        const_set(:Application, app)
        app.initialize!

        app
      end
  end
end
