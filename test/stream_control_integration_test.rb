# frozen_string_literal: true

require "test_helper"

class StreamControlIntegrationTest < Minitest::Test
  @@port_counter = 6000

  def setup
    @@port_counter += 1
    @port = @@port_counter
    @client = nil
    @server = nil
    @server_thread = nil
  end

  def teardown
    @client&.disconnect rescue nil
    # drain kills handler threads before tearing down MsQuic
    @server&.stop rescue nil
    @server_thread&.join(3)
  end

  def test_client_cancel_sends_reset_to_server
    app = ->(env) {
      sleep 2
      [200, {}, ["OK"]]
    }

    start_server_and_client(app)

    request = @client.build_request("GET", "/slow")

    sleep 0.1
    assert request.pending?, "Request should still be pending"

    result = request.cancel
    assert result, "Cancel should return true"
    assert request.cancelled?, "Request should be cancelled"
    refute request.completed?, "Request should not be completed"
  end

  def test_server_error_response
    app = ->(env) { [500, {}, ["Error"]] }

    start_server_and_client(app)

    response = @client.get("/test")
    assert_equal 500, response[:status]
  end

  def test_block_based_cancel
    app = ->(env) {
      sleep 2
      [200, {}, ["OK"]]
    }

    start_server_and_client(app)

    cancelled = false
    timed_out = false

    begin
      @client.get("/slow") do |req|
        sleep 0.1
        req.cancel
        cancelled = req.cancelled?
        req.response(timeout: 0.5)
      end
    rescue Quicsilver::TimeoutError
      timed_out = true
    end

    assert cancelled, "Request should have been cancelled in block"
    assert timed_out, "Should timeout after cancel"
  end

  def test_server_shutdown_completes_inflight_requests
    request_started = Queue.new

    app = ->(env) {
      request_started.push(true)
      sleep 0.5
      [200, {}, ["OK"]]
    }

    start_server_and_client(app)

    response_thread = Thread.new { @client.get("/slow") }
    request_started.pop(timeout: 2)

    shutdown_thread = Thread.new { @server.shutdown(timeout: 5) }

    response = response_thread.value
    assert_equal 200, response[:status]

    shutdown_thread.join(10)
    refute @server.running?, "Server should be stopped after shutdown"
  end

  def test_concurrent_requests_with_cancel
    app = ->(env) {
      path = env["PATH_INFO"]
      sleep(path == "/slow" ? 2 : 0.1)
      [200, {}, ["Path: #{path}"]]
    }

    start_server_and_client(app)

    fast_req = @client.build_request("GET", "/fast")
    slow_req = @client.build_request("GET", "/slow")

    sleep 0.05
    slow_req.cancel

    fast_response = fast_req.response(timeout: 3)
    assert_equal 200, fast_response[:status]
    assert_match(/fast/, fast_response[:body])

    assert slow_req.cancelled?
  end

  def test_shutdown_with_stuck_request_drains_cleanly
    request_started = Queue.new

    app = ->(env) {
      request_started.push(true)
      sleep 999  # Intentionally blocks forever
      [200, {}, ["never"]]
    }

    start_server_and_client(app)

    # Fire a request that will never complete
    response_thread = Thread.new { @client.get("/stuck") }
    response_thread.report_on_exception = false
    request_started.pop(timeout: 2)

    # Shutdown with a short drain timeout — forces DrainTimeoutError
    shutdown_thread = Thread.new { @server.shutdown(timeout: 2) }
    shutdown_thread.join(10)

    refute @server.running?, "Server should be stopped after shutdown"
    assert @server.request_registry.empty?, "Request registry should be cleaned up"
  end

  def test_max_concurrent_requests_limits_concurrency
    request_count = Queue.new

    app = ->(env) {
      request_count.push(true)
      sleep 0.3
      [200, {}, ["OK"]]
    }

    # Server allows only 2 concurrent bidi streams
    config = Quicsilver::ServerConfiguration.new(cert_file_path, key_file_path, max_concurrent_requests: 2)
    @server = Quicsilver::Server.new(@port, server_configuration: config, app: app)
    @server_thread = Thread.new { @server.start }
    sleep 0.5

    @client = Quicsilver::Client.new("localhost", @port, connection_timeout: 5000, request_timeout: 10)
    @client.connect

    # Fire 3 requests concurrently — MsQuic should queue the 3rd
    threads = 3.times.map { |i| Thread.new { @client.get("/req#{i}") } }

    # All 3 should eventually complete (3rd waits for a slot)
    responses = threads.map { |t| t.value }
    assert_equal 3, responses.size
    responses.each { |r| assert_equal 200, r[:status] }
  end

  def test_cancel_after_disconnect_does_not_crash
    app = ->(env) {
      sleep 2
      [200, {}, ["OK"]]
    }

    start_server_and_client(app)

    request = @client.build_request("GET", "/slow")
    sleep 0.1

    # Disconnect first — stream handle becomes stale
    @client.disconnect

    # Cancel on a stale handle should not segfault
    result = request.cancel
    refute result, "Cancel should return false on stale handle"
  end

  # Regression: response bodies with non-ASCII bytes (e.g. JSON from MySQL)
  # caused Encoding::CompatibilityError when concatenating binary C data
  # with a UTF-8 StringIO buffer in Client#handle_stream_event.
  def test_non_ascii_response_body_does_not_raise_encoding_error
    unicode_body = '{"name":"Héllo Wörld 🚀","emoji":"✅"}'

    app = ->(env) {
      [200, { "content-type" => "application/json; charset=utf-8" }, [unicode_body]]
    }

    start_server_and_client(app)

    response = @client.get("/unicode")
    assert_equal 200, response[:status]
    assert_equal unicode_body, response[:body].force_encoding("UTF-8")
  end

  private

  def start_server_and_client(app)
    @server = Quicsilver::Server.new(@port, server_configuration: default_server_config, app: app)
    @server_thread = Thread.new { @server.start }
    sleep 0.5

    @client = Quicsilver::Client.new("localhost", @port, connection_timeout: 5000, request_timeout: 10)
    @client.connect
    assert @client.connected?, "Client should be connected"
  end

  def default_server_config
    Quicsilver::ServerConfiguration.new(cert_file_path, key_file_path)
  end
end
