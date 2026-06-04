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
