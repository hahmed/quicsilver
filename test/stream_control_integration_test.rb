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
