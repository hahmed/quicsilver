# frozen_string_literal: true

require "test_helper"

class ServerStatsIntegrationTest < Minitest::Test
  def setup
    @server = nil
    @server_thread = nil
    @clients = []
  end

  def teardown
    @clients.each { |client| client.disconnect rescue nil }
    @server&.stop rescue nil
    @server_thread&.join(3)
  end

  def test_stats_reports_multiple_connections_and_transport_counters
    app = ->(env) {
      case env["PATH_INFO"]
      when "/hello"
        [200, { "content-type" => "text/plain" }, ["hello"]]
      else
        [404, { "content-type" => "text/plain" }, ["not found"]]
      end
    }
    start_server(app)

    @clients = 2.times.map { Quicsilver::Client.new("127.0.0.1", @port, unsecure: true) }
    @clients.each do |client|
      response = client.get("/hello")
      assert_equal 200, response.status
      assert_equal "hello", response.body
    end

    wait_until { @server.stats.dig("connections", "active") >= 2 }

    stats = @server.stats
    transport = stats["transport"]

    assert_operator stats.dig("connections", "active"), :>=, 2
    assert_equal 100, stats.dig("connections", "max")
    assert_equal 0, stats.dig("requests", "active")
    assert_kind_of Hash, transport
    assert_includes transport, "connections_active"
    assert_includes transport, "connections_connected"
    assert_includes transport, "streams_active"
    assert_includes transport, "worker_operations_queue_depth"
  end

  private

  def start_server(app)
    @port = find_available_port
    config = Quicsilver::Transport::Configuration.new(cert_file_path, key_file_path)
    @server = Quicsilver::Server.new(@port, app: app, server_configuration: config)
    @server_thread = Thread.new { @server.start }
    wait_for_server(@server)
  end

  def wait_until(timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "condition was not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end
end
