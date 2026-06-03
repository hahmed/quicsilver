# frozen_string_literal: true

require "test_helper"

class ServerStatsTest < Minitest::Test
  def test_stats_combines_server_state_with_transport_counters
    server = build_server(threads: 2, max_queue_size: 7, max_connections: 11)
    server.request_registry.track(123, 456, path: "/stats", method: "GET")

    transport_counters = {
      "connections_active" => 4,
      "streams_active" => 8,
      "worker_operations_queue_depth" => 2,
      "connections_load_rejected" => 1
    }

    Quicsilver.stub(:transport_counters, transport_counters) do
      stats = server.stats

      refute stats["running"]
      refute stats["shutting_down"]
      assert_equal({"active" => 0, "max" => 11}, stats["connections"])
      assert_equal({"active" => 1}, stats["requests"])
      assert_equal 2, stats.dig("scheduler", "threads")
      assert_equal 0, stats.dig("scheduler", "pending")
      assert_equal 7, stats.dig("scheduler", "max_queue_size")
      refute stats.dig("scheduler", "full")
      assert_same transport_counters, stats["transport"]
    end
  end

  def test_stats_returns_nil_transport_counters_before_native_initialization
    server = build_server

    uninitialized = proc { raise RuntimeError, "QUIC transport not initialized." }

    Quicsilver.stub(:transport_counters, uninitialized) do
      assert_nil server.stats["transport"]
    end
  end

  def test_transport_counters_native_method_is_exposed
    assert Quicsilver.respond_to?(:transport_counters)
  end

  private

  def build_server(**options)
    config = Quicsilver::Transport::Configuration.new(cert_file_path, key_file_path)
    Quicsilver::Server.new(4433, server_configuration: config, **options)
  end
end
