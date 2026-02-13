# frozen_string_literal: true

require "test_helper"
require_relative "../lib/quicsilver/event_loop"

class EventLoopTest < Minitest::Test
  def test_wake_is_callable
    Quicsilver.open_connection
    Quicsilver.wake
  end

  def test_wake_does_not_crash_when_called_multiple_times
    Quicsilver.open_connection
    10.times { Quicsilver.wake }
  end

  def test_stop_unblocks_event_loop_quickly
    Quicsilver.open_connection
    loop_instance = Quicsilver::EventLoop.new
    loop_instance.start

    # Give the loop thread time to enter its poll wait
    sleep(0.05)

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    loop_instance.stop
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    # With wake, stop should return well under 1s (the new max wait).
    # Without wake, it could take up to 1s. Allow generous 500ms threshold.
    assert elapsed < 0.5, "EventLoop#stop took #{elapsed}s — wake may not be working"
  end

  def test_request_completes_under_100ms
    server = create_server(4470)
    server_thread = Thread.new { server.start }
    sleep(0.3)

    client = Quicsilver::Client.new("localhost", 4470, connection_timeout: 5000)

    begin
      client.connect
      assert client.connected?, "Client should be connected"

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      response = client.get("/") { |_req| }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

      # With wake, round-trip should be fast (no 100ms stalls per hop).
      # Allow 80ms — if it's timeout-driven, it would take ~200-300ms (multiple 100ms waits).
      assert elapsed < 0.08, "GET took #{(elapsed * 1000).round(1)}ms — expected <80ms with wake"
    rescue Quicsilver::ConnectionError, Quicsilver::TimeoutError => e
      skip "Connection failed in test environment: #{e.message}"
    ensure
      client.disconnect if client.connected?
      server.stop if server.running?
      server_thread&.join(2)
    end
  end

  private

  def create_server(port)
    config = Quicsilver::ServerConfiguration.new(cert_file_path, key_file_path)
    app = ->(env) { [200, { "content-type" => "text/plain" }, ["OK"]] }
    Quicsilver::Server.new(port, server_configuration: config, app: app)
  end
end
