# frozen_string_literal: true

require "test_helper"

class ServerStatsTest < Minitest::Test
  class TestScheduler < Quicsilver::Server::Scheduler
    def initialize(concurrency:, max_queue_size:, &handler)
    end

    def enqueue(work)
    end

    def full?
      false
    end

    def pending
      0
    end

    def drain(timeout: 5)
    end

    def start
    end

    def stop
    end
  end

  class FullScheduler < TestScheduler
    def full?
      true
    end
  end

  class SlowDrainScheduler < TestScheduler
    def drain(timeout: 5)
      sleep 0.2
    end
  end

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

      assert_nil stats["cibir"]
      refute stats["running"]
      refute stats["ready"]
      refute stats["draining"]
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

  def test_ready_is_false_when_server_is_not_running
    server = build_server

    refute server.ready?
    refute server.draining?
  end

  def test_ready_is_true_when_running_and_accepting_work
    server = build_server(scheduler: TestScheduler)
    server_thread = start_server(server)

    assert server.ready?
    refute server.draining?
  ensure
    stop_server(server, server_thread)
  end

  def test_ready_is_false_while_draining
    server = build_server(scheduler: SlowDrainScheduler)
    server_thread = start_server(server)
    shutdown_thread = Thread.new { server.shutdown(timeout: 1) }

    wait_until { server.draining? }

    assert server.draining?
    refute server.ready?
  ensure
    shutdown_thread&.join(2)
    stop_server(server, server_thread)
  end

  def test_ready_is_false_when_scheduler_queue_is_full
    server = build_server(scheduler: FullScheduler)
    server_thread = start_server(server)

    refute server.ready?
    refute server.draining?
  ensure
    stop_server(server, server_thread)
  end

  def test_connection_snapshots_include_connection_id_and_cibir_id
    server = build_server
    connection = Quicsilver::Transport::Connection.new(
      123,
      [123, 0, false],
      connection_id: "\xab\xcd".b,
      cibir_id: "\x01".b
    )
    server.connections[connection.handle] = connection

    Quicsilver.stub(:connection_statistics, connection_statistics) do
      snapshot = server.connection_snapshots.first

      assert_equal "abcd", snapshot["connection_id"]
      assert_equal "01", snapshot["cibir_id"]
      assert_equal 0, snapshot.dig("transport", :rtt)
    end
  end

  def test_stats_exposes_configured_cibir
    server = build_server(cibir_id: "00010203", cibir_offset: 0)

    assert_equal({ "id" => "00010203", "offset" => 0 }, server.stats["cibir"])
  end

  def test_server_starts_with_configured_cibir
    server = build_server(cibir_id: "01")
    server_thread = start_server(server)

    assert server.running?
    assert_equal({ "id" => "01", "offset" => 0 }, server.stats["cibir"])
  ensure
    stop_server(server, server_thread)
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

  def connection_statistics
    {
      "rtt" => 0,
      "min_rtt" => 0,
      "max_rtt" => 0,
      "resumption_attempted" => false,
      "resumption_succeeded" => false,
      "send_path_mtu" => 0,
      "send_total_packets" => 0,
      "send_retransmittable_packets" => 0,
      "send_suspected_lost_packets" => 0,
      "send_spurious_lost_packets" => 0,
      "send_total_bytes" => 0,
      "send_total_stream_bytes" => 0,
      "send_congestion_count" => 0,
      "send_persistent_congestion_count" => 0,
      "send_congestion_window" => 0,
      "recv_total_packets" => 0,
      "recv_reordered_packets" => 0,
      "recv_dropped_packets" => 0,
      "recv_duplicate_packets" => 0,
      "recv_total_bytes" => 0,
      "recv_total_stream_bytes" => 0,
      "recv_decryption_failures" => 0,
      "recv_valid_ack_frames" => 0,
      "key_update_count" => 0
    }
  end

  def build_server(cibir_id: nil, cibir_offset: nil, **options)
    config_options = {}
    config_options[:cibir_id] = cibir_id if cibir_id
    config_options[:cibir_offset] = cibir_offset unless cibir_offset.nil?
    config = Quicsilver::Transport::Configuration.new(cert_file_path, key_file_path, config_options)
    Quicsilver::Server.new(find_available_port, server_configuration: config, **options)
  end

  def start_server(server)
    Thread.new { server.start }.tap do
      wait_for_server(server)
    end
  end

  def stop_server(server, server_thread)
    server&.stop if server&.running?
    server_thread&.join(2)
  end

  def wait_until(timeout: 3)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      flunk "condition was not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end
end
