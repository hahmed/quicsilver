require "bundler/setup"
require "quicsilver"
require "localhost/authority"

module Benchmarks
  module Helpers
    # Boot a Quicsilver server on a random port, yield the port, then tear down.
    def self.with_server(app, &block)
      authority = Localhost::Authority.fetch
      config = Quicsilver::ServerConfiguration.new(
        authority.certificate_path,
        authority.key_path
      )

      port = random_port
      server = Quicsilver::Server.new(port, app: app, server_configuration: config)
      server_thread = Thread.new { server.start }
      sleep 0.5 # let listener settle

      yield port
    ensure
      server&.stop rescue nil
      server_thread&.join(2)
    end

    # Compute latency stats from an array of float durations (in seconds).
    # Returns a Hash with :avg, :min, :max, :p50, :p95, :p99 (all in ms).
    def self.stats(times)
      return nil if times.empty?

      sorted = times.sort
      n = sorted.size
      {
        count: n,
        avg:   (times.sum / n * 1000).round(2),
        min:   (sorted.first * 1000).round(2),
        max:   (sorted.last * 1000).round(2),
        p50:   (sorted[n / 2] * 1000).round(2),
        p95:   (sorted[(n * 0.95).to_i] * 1000).round(2),
        p99:   (sorted[(n * 0.99).to_i] * 1000).round(2)
      }
    end

    def self.print_header(title, **opts)
      puts
      puts "=" * 60
      puts title
      puts "=" * 60
      opts.each { |k, v| puts "  #{k}: #{v}" }
      puts "-" * 60
    end

    def self.print_stats(label, times)
      s = stats(times)
      unless s
        puts "  #{label}: no data"
        return
      end
      puts "  #{label}: #{s[:count]} reqs | avg=#{s[:avg]}ms p50=#{s[:p50]}ms p95=#{s[:p95]}ms p99=#{s[:p99]}ms (min=#{s[:min]}ms max=#{s[:max]}ms)"
    end

    def self.print_results(total_time:, total_requests:, times:, failed: 0, latency: false)
      s = stats(times)
      puts "-" * 60
      puts "  Total time:  #{total_time.round(3)}s"
      puts "  Requests:    #{total_requests} (#{failed} failed)"
      puts "  Throughput:  #{(total_requests / total_time).round(2)} req/s"
      if latency && s
        puts "  Latency:     avg=#{s[:avg]}ms p50=#{s[:p50]}ms p95=#{s[:p95]}ms p99=#{s[:p99]}ms"
        puts "               min=#{s[:min]}ms max=#{s[:max]}ms"
      end
      puts "=" * 60
    end

    def self.random_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end

    def self.benchmark_app
      ->(env) {
        [200, { "content-type" => "text/plain" }, ["OK"]]
      }
    end
  end
end
